"""Measure and independently check final filesystem observation for wide layers."""
import argparse
import hashlib
import io
import json
from pathlib import Path
from statistics import median
import subprocess
import tarfile
import tempfile
from time import perf_counter

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def make_layout(root, count):
    blobs = root / 'blobs' / 'sha256'
    blobs.mkdir(parents=True)

    def encode(value):
        return json.dumps(value, separators=(',', ':')).encode()

    def put(media, data):
        digest = sha(data)
        (blobs / digest.split(':')[1]).write_bytes(data)
        return {'mediaType': media, 'digest': digest, 'size': len(data)}

    def layer(paths):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w', format=tarfile.USTAR_FORMAT) as archive:
            for path, body in paths:
                member = tarfile.TarInfo(path)
                member.size = len(body)
                archive.addfile(member, io.BytesIO(body))
        return put('application/vnd.oci.image.layer.v1.tar', buffer.getvalue())

    base = [(f'app/item-{i:06d}', f'{i}\n'.encode()) for i in range(count)]
    update = [('app/.wh.item-000000', b''), ('app/item-000001', b'changed\n'),
              ('new/version', b'new\n')]
    layers = [layer(base), layer(update)]
    config = put('application/vnd.oci.image.config.v1+json', encode({
        'architecture': 'amd64', 'os': 'linux',
        'rootfs': {'type': 'layers', 'diff_ids': [item['digest'] for item in layers]},
    }))
    manifest = put('application/vnd.oci.image.manifest.v1+json', encode({
        'schemaVersion': 2, 'mediaType': 'application/vnd.oci.image.manifest.v1+json',
        'config': config, 'layers': layers,
    }))
    (root / 'oci-layout').write_bytes(b'{"imageLayoutVersion":"1.0.0"}')
    (root / 'index.json').write_bytes(encode({
        'schemaVersion': 2, 'manifests': [
            {**manifest, 'platform': {'os': 'linux', 'architecture': 'amd64'}},
        ],
    }))
    expected = dict(base)
    expected.pop('app/item-000000')
    expected.update(update[1:])
    return {path: (sha(data), int(path in dict(update[1:]))) for path, data in expected.items()}


def measure(binary, layout, expected, runs):
    timings = []
    stdout = None
    for _ in range(runs):
        start = perf_counter()
        result = subprocess.run([str(binary), 'files', str(layout), 'linux', 'amd64'],
                                capture_output=True, timeout=240)
        if result.returncode:
            raise RuntimeError((binary.name, result.returncode, result.stderr.decode('utf-8')))
        timings.append((perf_counter() - start) * 1000)
        if stdout is not None:
            assert result.stdout == stdout
        stdout = result.stdout
        entries = json.loads(stdout)['entries']
        observed = {entry['path']: (entry['content_digest'], entry['layer_index']) for entry in entries}
        assert len(entries) == len(observed) and observed == expected
    return median(timings), stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--entries', type=int, nargs='+', default=[1000, 4000])
    parser.add_argument('--runs', type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.runs <= 10 or any(not 2 <= n <= 20000 for n in args.entries):
        parser.error('use 1..10 runs and 2..20000 entries')
    work = Path(tempfile.mkdtemp(prefix='rootfs-workload-', dir=ROOT / '_build'))
    measurements = []
    for case, count in enumerate(args.entries):
        layout = work / f'{case}-{count}'
        expected = make_layout(layout, count)
        current, output = measure(args.binary.resolve(), layout, expected, args.runs)
        entry = dict(entries=count, current_median_ms=round(current, 3), inventory=sha(output))
        if args.baseline:
            baseline, old_output = measure(args.baseline.resolve(), layout, expected, args.runs)
            assert old_output == output
            entry['baseline_median_ms'] = round(baseline, 3)
        measurements.append(entry)
    report = dict(schema='moonoci.rootfs-workload.v1', runs=args.runs, measurements=measurements)
    (work / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
