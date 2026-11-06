"""Windows/Linux restartable delivery, independently checked with CPython.

Each command is a fresh process. No daemon, registry credentials or VM required.
This tests process restart between arrivals, not sudden power-loss durability.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from independent_layout import observe

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = Path(tempfile.mkdtemp(prefix='resume-', dir=ROOT / '_build'))

    def run(*arguments, status=0):
        result = subprocess.run([str(binary), *map(str, arguments)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=120)
        if result.returncode != status:
            raise AssertionError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout.strip()

    source = directory / 'rootfs'
    source.mkdir()
    (source / 'common.bin').write_bytes(bytes(range(256)) * 256)
    for name in ('base', 'target'):
        if name == 'target':
            (source / 'new.bin').write_bytes(bytes(reversed(range(256))) * 1024)
        specification = directory / (name + '.json')
        specification.write_text(json.dumps(dict(schemaVersion=1, ref='resume',
            platform=dict(os='linux', architecture='amd64'),
            layers=[dict(source=str(source), compression='none')],
            output=dict(layout=str(directory / name)))), encoding='utf-8')
        run('build', specification)

    envelope = directory / 'update.tar'
    run('delta-pack', directory / 'base', directory / 'target', envelope)
    payload = envelope.read_bytes()
    pin = digest(payload)  # Independent release metadata in a real host.
    chunk_bytes = 16384
    chunks = [payload[i:i + chunk_bytes] for i in range(0, len(payload), chunk_bytes)]
    plan_path = directory / 'plan.json'
    assert run('chunk-plan', envelope, chunk_bytes, plan_path) == pin
    plan_raw = plan_path.read_bytes()
    plan = json.loads(plan_raw)
    assert plan == dict(format='moonoci.chunks.v1', digest=pin, size=str(len(payload)),
                        chunk_bytes=chunk_bytes, chunks=[digest(c) for c in chunks])
    run('chunk-plan', envelope, chunk_bytes, plan_path, status=3)
    assert plan_path.read_bytes() == plan_raw
    paths = []
    for index, chunk in enumerate(chunks):
        path = directory / ('chunk-' + str(index))
        run('chunk-export', envelope, plan_path, pin, index, path)
        assert path.read_bytes() == chunk
        paths.append(path)

    session = directory / 'session'
    run('transfer-start', plan_path, pin, session)
    run('transfer-start', plan_path, pin, session, status=3)
    assert json.loads(run('transfer-status', session, pin))['missing'] == list(range(len(chunks)))
    first = list(range(0, len(chunks), 3))[::-1]
    for index in first:
        run('transfer-put', session, pin, index, paths[index])
    run('transfer-put', session, pin, first[0], paths[first[0]])  # Idempotent.
    progress = json.loads(run('transfer-status', session, pin))
    missing = [i for i in range(len(chunks)) if i not in first]
    assert progress['missing'] == missing
    reused_bytes = sum(len(chunks[i]) for i in first)
    assert int(progress['received_bytes']) == reused_bytes
    assert (session / 'plan.json').read_bytes() == plan_raw
    incomplete = directory / 'incomplete.tar'
    run('transfer-finish', session, pin, incomplete, status=5)
    assert not incomplete.exists() and not Path(str(incomplete) + '.moonoci-partial').exists()
    run('transfer-status', session, digest(b'wrong release'), status=5)
    bad = directory / 'bad-chunk'
    bad.write_bytes(b'X' * len(chunks[missing[0]]))
    run('transfer-put', session, pin, missing[0], bad, status=5)
    assert not (session / 'chunks' / str(missing[0])).exists()

    # Independent processes recover actual files; send only the missing set.
    batches = 0
    while True:
        batch = json.loads(run('transfer-batch', session, pin, 3, 2 * chunk_bytes))
        if not batch['chunks']:
            break
        assert len(batch['chunks']) <= 3 and int(batch['bytes']) <= 2 * chunk_bytes
        assert [c['index'] for c in batch['chunks']] == sorted(c['index'] for c in batch['chunks'])
        for item in batch['chunks'][::-1]:
            index = item['index']
            assert index in missing
            assert int(item['offset']) == index * chunk_bytes
            assert item['size'] == len(chunks[index]) and item['digest'] == digest(chunks[index])
            run('transfer-put', session, pin, index, paths[index])
        batches += 1
    assert json.loads(run('transfer-status', session, pin))['all_chunks_present']
    restored_archive = directory / 'received.tar'
    run('transfer-finish', session, pin, restored_archive)
    assert restored_archive.read_bytes() == payload
    run('transfer-finish', session, pin, restored_archive, status=3)
    assert restored_archive.read_bytes() == payload
    target_pin = digest((directory / 'target' / 'index.json').read_bytes())
    restored_layout = directory / 'restored-layout'
    run('delta-apply', directory / 'base', restored_archive, target_pin, restored_layout)
    assert observe(restored_layout) == observe(directory / 'target')

    # Stored chunks are rechecked after restart, even if formerly accepted.
    (session / 'chunks' / '0').write_bytes(b'X' * len(chunks[0]))
    run('transfer-status', session, pin, status=5)
    run('transfer-batch', session, pin, 0, chunk_bytes, status=2)
    run('transfer-batch', session, pin, 1, 0, status=2)
    corrupt_output = directory / 'corrupt-output'
    run('transfer-finish', session, pin, corrupt_output, status=5)
    assert not corrupt_output.exists()
    assert not Path(str(corrupt_output) + '.moonoci-partial').exists()

    # Attacker-controlled per-chunk metadata can all pass yet fail whole pin.
    forged_chunks = list(chunks)
    forged_chunks[0] = bytes([chunks[0][0] ^ 1]) + chunks[0][1:]
    forged = {**plan, 'chunks': [digest(c) for c in forged_chunks]}
    forged_path = directory / 'forged-plan.json'
    forged_path.write_text(json.dumps(forged), encoding='utf-8')
    forged_session = directory / 'forged-session'
    run('transfer-start', forged_path, pin, forged_session)
    for index, chunk in enumerate(forged_chunks):
        path = directory / ('forged-' + str(index))
        path.write_bytes(chunk)
        run('transfer-put', forged_session, pin, index, path)
    assert json.loads(run('transfer-status', forged_session, pin))['all_chunks_present']
    forged_output = directory / 'forged-output'
    run('transfer-finish', forged_session, pin, forged_output, status=5)
    assert not forged_output.exists()
    assert not Path(str(forged_output) + '.moonoci-partial').exists()

    empty = directory / 'empty'
    empty.write_bytes(b'')
    empty_pin = run('chunk-plan', empty, 1, directory / 'empty-plan.json')
    run('transfer-start', directory / 'empty-plan.json', empty_pin, directory / 'empty-session')
    run('transfer-finish', directory / 'empty-session', empty_pin, directory / 'empty-output')
    assert (directory / 'empty-output').read_bytes() == b''

    # Model the exact on-disk states left at commit boundaries. This is not a
    # power-loss or live kill test. Verified recovery must preserve bad inputs.
    recovery = directory / 'recovery-session'
    run('transfer-start', plan_path, pin, recovery)
    assert run('transfer-recover-chunk', recovery, pin, 0) == 'missing'
    (recovery / 'chunks' / '0.pending').write_bytes(chunks[0])
    assert run('transfer-recover-chunk', recovery, pin, 0) == 'recovered'
    assert run('transfer-recover-chunk', recovery, pin, 0) == 'committed'
    (recovery / 'chunks' / '1.pending').write_bytes(b'bad')
    run('transfer-recover-chunk', recovery, pin, 1, status=5)
    assert (recovery / 'chunks' / '1.pending').read_bytes() == b'bad'
    recovered_output = directory / 'recovered-output'
    partial = Path(str(recovered_output) + '.moonoci-partial')
    partial.write_bytes(payload)
    run('transfer-recover-output', recovery, pin, recovered_output)
    assert recovered_output.read_bytes() == payload and not partial.exists()
    bad_output = directory / 'bad-recovery-output'
    bad_partial = Path(str(bad_output) + '.moonoci-partial')
    bad_partial.write_bytes(bytes([payload[0] ^ 1]) + payload[1:])
    run('transfer-recover-output', recovery, pin, bad_output, status=5)
    assert bad_partial.exists() and not bad_output.exists()
    report = dict(schema='moonoci.resumable-consumer.v1', source_bytes=len(payload),
                  chunk_bytes=chunk_bytes, chunks=len(chunks), reused_bytes=reused_bytes,
                  remaining_bytes=len(payload) - reused_bytes, process_restart_verified=True,
                  whole_pin=pin, independent_chunk_hashes=True, delta_hydration_verified=True,
                  corrupt_cache_refused=True, forged_chunk_metadata_refused=True,
                  no_overwrite=True, empty_file_verified=True, pending_recovery_verified=True,
                  complete_partial_recovery_verified=True, bad_partial_preserved=True,
                  bounded_batches=batches, power_loss_tested=False)
    (directory / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
