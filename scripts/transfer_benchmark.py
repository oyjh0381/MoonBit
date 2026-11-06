"""Measure bounded producer workloads, independently checking every chunk.

Wall times include CLI startup and plan filesystem output. No speedup or RSS
claim is made. Fixtures and machine-readable measurements stay under _build.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--size-mib', type=int, default=32)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--chunk-bytes', nargs='+', type=int, default=[512, 16384, 1048576, 16777216])
    args = parser.parse_args()
    if not 1 <= args.size_mib <= 512 or not 1 <= args.runs <= 10:
        parser.error('size-mib must be 1..512 and runs 1..10')
    if any(not 1 <= c <= 16777216 for c in args.chunk_bytes):
        parser.error('chunk-bytes must be 1..16777216')
    size = args.size_mib * 1048576
    if any((size - 1) // c + 1 > 65536 for c in args.chunk_bytes):
        parser.error('workload exceeds the 65536 chunk quota')
    binary = args.binary.resolve()
    directory = Path(tempfile.mkdtemp(prefix='transfer-bench-', dir=ROOT / '_build'))
    source = directory / 'source.bin'
    block = bytes(range(256)) * 4096
    whole = hashlib.sha256()
    with source.open('wb') as output:
        for mib in range(args.size_mib):
            indexed = bytearray(block)
            for offset in range(0, len(indexed), 512):
                indexed[offset:offset + 8] = (mib * len(block) + offset).to_bytes(8, 'little')
            output.write(indexed)
            whole.update(indexed)
    pin = 'sha256:' + whole.hexdigest()
    observations = []
    for chunk_bytes in args.chunk_bytes:
        timings = []
        plans = []
        for run in range(args.runs):
            path = directory / f'plan-{chunk_bytes}-{run}.json'
            start = time.perf_counter()
            result = subprocess.run([str(binary), 'chunk-plan', str(source), str(chunk_bytes), str(path)],
                                    capture_output=True, text=True, encoding='utf-8', timeout=180, check=True)
            timings.append(round((time.perf_counter() - start) * 1000, 3))
            assert result.stdout.strip() == pin
            plans.append(path.read_bytes())
        assert all(plan == plans[0] for plan in plans)
        plan = json.loads(plans[0])
        expected_chunks = []
        with source.open('rb') as stream:
            while chunk := stream.read(chunk_bytes):
                expected_chunks.append(sha(chunk))
        assert plan == dict(format='moonoci.chunks.v1', digest=pin, size=str(size),
                            chunk_bytes=chunk_bytes, chunks=expected_chunks)
        session = directory / f'session-{chunk_bytes}'
        subprocess.run([str(binary), 'transfer-start', str(directory / f'plan-{chunk_bytes}-0.json'),
                        pin, str(session)], capture_output=True, text=True, timeout=180, check=True)
        assert (session / 'plan.json').read_bytes() == plans[0]
        observations.append(dict(chunk_bytes=chunk_bytes, chunks=len(expected_chunks),
                                 plan_bytes=len(plans[0]), elapsed_ms=timings,
                                 median_ms=round(statistics.median(timings), 3),
                                 independent_digests=True, deterministic=True, plan_decode_verified=True))
    # Count quota must reject before reading/hashing this source, without output.
    oversized = directory / 'too-many-chunks.bin'
    with oversized.open('wb') as stream:
        stream.truncate(65536 * 512 + 1)
    rejected_plan = directory / 'must-not-exist.json'
    rejected = subprocess.run([str(binary), 'chunk-plan', str(oversized), '512', str(rejected_plan)],
                              capture_output=True, text=True, timeout=30)
    assert rejected.returncode == 5 and 'MOONOCI_RESOURCE_LIMIT' in rejected.stderr
    assert not rejected_plan.exists()
    try:
        revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip())
    except (OSError, subprocess.SubprocessError):
        revision, dirty = None, None
    binary_hash = hashlib.sha256()
    with binary.open('rb') as stream:
        while part := stream.read(1048576):
            binary_hash.update(part)
    report = dict(schema='moonoci.transfer-workload.v1', os=platform.platform(),
                  source_bytes=size, runs=args.runs, whole_pin=pin,
                  cli_version=subprocess.check_output([str(binary), 'version'], text=True).strip(),
                  source_revision=revision, source_dirty=dirty, binary_sha256=binary_hash.hexdigest(),
                  python=platform.python_version(), cpu=platform.processor(), logical_cpus=os.cpu_count(),
                  fixture='position-indexed-512-byte-blocks', cases=observations,
                  chunk_count_overflow_refused=True, peak_memory_measured=False)
    (directory / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
