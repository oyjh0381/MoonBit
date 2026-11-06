"""Synthetic mixed-store retention curves with literal independent closures.

Includes filesystem loading, hashes, planning and (separately) verified copy
publication. Not a comparison with registry GC, a deletion or a production SLO.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def pin(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--buffered', action='store_true', help='explicitly skip per-file data synchronization for reconstructible output copies')
    args = parser.parse_args()
    if not 1 <= args.runs <= 5:
        parser.error('runs must be 1..5')
    binary = args.binary.resolve()
    directory = Path(tempfile.mkdtemp(prefix='retention-bench-', dir=ROOT / '_build'))

    def run(*arguments):
        result = subprocess.run([str(binary), *map(str, arguments)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=180)
        if result.returncode:
            raise AssertionError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout.strip()

    source = directory / 'rootfs'
    source.mkdir()
    (source / 'app').write_bytes(b'shared application payload')
    specification = directory / 'seed.json'
    seed = directory / 'seed'
    specification.write_bytes(encode(dict(schemaVersion=1, ref='seed', layers=[dict(source=str(source), compression='none')],
                                         output=dict(layout=str(seed)))))
    run('build', specification)
    seed_index = json.loads((seed / 'index.json').read_bytes())
    seed_manifest = json.loads((seed / 'blobs/sha256' / seed_index['manifests'][0]['digest'].split(':')[1]).read_bytes())
    seed_config = json.loads((seed / 'blobs/sha256' / seed_manifest['config']['digest'].split(':')[1]).read_bytes())
    cases = []
    for count in (100, 1000):
        store = directory / f'store-{count}'
        shutil.copytree(seed, store)

        def put(media, data):
            descriptor = dict(mediaType=media, digest=pin(data), size=len(data))
            path = store / 'blobs/sha256' / descriptor['digest'].split(':')[1]
            if not path.exists():
                path.write_bytes(data)
            return descriptor

        config_media = 'application/vnd.oci.image.config.v1+json'
        manifest_media = 'application/vnd.oci.image.manifest.v1+json'
        index_media = 'application/vnd.oci.image.index.v1+json'
        empty = put('application/vnd.oci.empty.v1+json', b'{}')
        roots, closures = [], []
        for index in range(count):
            config = json.loads(encode(seed_config))
            config.setdefault('config', {}).setdefault('Labels', {})['example.component'] = str(index)
            config_descriptor = put(config_media, encode(config))
            manifest = {**seed_manifest, 'config': config_descriptor}
            image = put(manifest_media, encode(manifest))
            payload = put('application/json', encode({'component': index, 'fixture': 'typed-attachment'}))
            attachment = put(manifest_media, encode(dict(schemaVersion=2, mediaType=manifest_media,
                artifactType='application/vnd.example.attachment.v1+json', config=empty, layers=[payload], subject=image)))
            roots.append(image)
            roots.append(attachment)
            closures.append({image['digest'], config_descriptor['digest'], attachment['digest'],
                             empty['digest'], payload['digest'], *[d['digest'] for d in seed_manifest['layers']]})
        group = put(index_media, encode(dict(schemaVersion=2, mediaType=index_media, manifests=roots)))
        root_bytes = encode(dict(schemaVersion=2, mediaType=index_media, manifests=[group]))
        (store / 'index.json').write_bytes(root_bytes)
        for index in range(64):
            put('application/octet-stream', f'unreferenced-{index}'.encode())
        physical = {}
        for path in (store / 'blobs/sha256').iterdir():
            data = path.read_bytes()
            assert pin(data) == 'sha256:' + path.name
            physical['sha256:' + path.name] = len(data)
        source_pin = pin(root_bytes)
        selections = [(10, [d['digest'] for d in roots[0:20:2]], set().union(*closures[:10]))]
        if count == 1000:
            selections.append((count, [group['digest']], set().union(*closures) | {group['digest']}))
        for selected_count, selection, expected in selections:
            planning, exporting = [], []
            for trial in range(args.runs):
                start = time.perf_counter()
                plan = json.loads(run('retain-plan', store, source_pin, 'referrers', *selection))
                planning.append(round((time.perf_counter() - start) * 1000, 3))
                assert set(plan['kept']) == expected
                assert set(plan['discarded']) == set(physical) - expected
                assert int(plan['reclaimable_bytes']) == sum(size for key, size in physical.items() if key not in expected)
                output = directory / f'export-{count}-{selected_count}-{trial}'
                start = time.perf_counter()
                command = 'retain-export-buffered' if args.buffered else 'retain-export'
                exported = json.loads(run(command, store, source_pin, plan['plan_pin'], 'referrers', output, *selection))
                exporting.append(round((time.perf_counter() - start) * 1000, 3))
                assert exported == plan
                actual = {pin(path.read_bytes()) for path in (output / 'blobs/sha256').iterdir()}
                assert actual == expected
                assert pin((output / 'index.json').read_bytes()) == plan['output_index']
            cases.append(dict(images=count, attachments=count, selected_images=selected_count,
                source_blobs=len(physical), source_bytes=sum(physical.values()), kept_blobs=len(expected),
                kept_bytes=sum(physical[key] for key in expected), planning_ms=planning, export_ms=exporting,
                planning_median_ms=round(statistics.median(planning), 3), export_median_ms=round(statistics.median(exporting), 3),
                independent_content_sets=True))
    report = dict(schema='moonoci.retention-workload.v1', os=platform.platform(), python=platform.python_version(),
                  runs=args.runs, binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), cases=cases,
                  write_profile='buffered' if args.buffered else 'data-synchronous',
                  peak_memory_measured=False, source_deletions=0)
    (directory / 'report.json').write_bytes(encode(report))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
