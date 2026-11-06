"""Windows/Linux offline update integration using a built Native MoonOCI CLI."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from independent_layout import observe

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = Path(tempfile.mkdtemp(prefix='offline-', dir=ROOT / '_build'))

    def run(*arguments, status=0):
        result = subprocess.run([str(binary), *map(str, arguments)], cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=120)
        if result.returncode != status:
            raise AssertionError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout

    # Shared base content is intentionally substantially larger than metadata.
    source = directory / 'rootfs'
    source.mkdir()
    (source / 'shared.bin').write_bytes(bytes(range(256)) * 256)
    for arch in ('amd64', 'arm64'):
        spec = dict(schemaVersion=1, ref='demo', platform=dict(os='linux', architecture=arch),
                    layers=[dict(source=str(source), compression='none')], output=dict(layout=str(directory / arch)))
        specification = directory / (arch + '.json')
        specification.write_text(json.dumps(spec), encoding='utf-8')
        run('build', specification)
    base, target = directory / 'amd64', directory / 'arm64'
    target_index = (target / 'index.json').read_bytes()
    pin = 'sha256:' + hashlib.sha256(target_index).hexdigest()
    archive = directory / 'delta.tar'
    run('delta-pack', base, target, archive)
    run('delta-pack', base, target, directory / 'again.tar')
    assert archive.read_bytes() == (directory / 'again.tar').read_bytes()
    preserved = archive.read_bytes()
    run('delta-pack', base, target, archive, status=3)
    assert archive.read_bytes() == preserved
    restored = directory / 'restored'
    run('delta-apply', base, archive, pin, restored)
    run('delta-apply', base, archive, pin, restored, status=3)
    assert observe(restored) == observe(target)
    assert (restored / 'index.json').read_bytes() == target_index
    full = directory / 'full.tar'
    run('archive', target, full)
    assert archive.stat().st_size < full.stat().st_size
    rejected = directory / 'must-not-exist'
    run('delta-apply', base, archive, 'sha256:' + '0' * 64, rejected, status=5)
    assert not rejected.exists()
    # Reconstruct another real layout and independently observe both platforms.
    combined = directory / 'multi'
    run('merge', combined, base, target)
    assert len(observe(combined)['images']) == 2
    chosen = directory / 'selected'
    run('select', combined, chosen, 'linux', 'arm64')
    assert observe(chosen) == observe(target)
    stats = json.loads(run('storage', restored))
    assert stats['reclaimable_bytes'] == '0'
    blocked = json.loads(run('gate', target, status=5))
    assert not blocked['allowed']
    assert any(f['code'] == 'nonroot-user-required' for f in blocked['findings'])
    report = dict(schema='moonoci.offline.v1', full_archive_bytes=full.stat().st_size,
                  delta_archive_bytes=archive.stat().st_size, target_pin=pin,
                  independently_observed=True, deterministic=True, wrong_pin_refused=True,
                  multi_platform_selection=True)
    (directory / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
