"""Externally construct nested OCI indexes with Python, then consume in MoonOCI."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from independent_layout import observe

ROOT = Path(__file__).resolve().parents[1]
INDEX = 'application/vnd.oci.image.index.v1+json'


def encoded(value):
    return json.dumps(value, separators=(',', ':'), ensure_ascii=True).encode()


def wrap(layout):
    content = (layout / 'index.json').read_bytes()
    digest = hashlib.sha256(content).hexdigest()
    (layout / 'blobs/sha256' / digest).write_bytes(content)
    root = dict(schemaVersion=2, mediaType=INDEX,
                manifests=[dict(mediaType=INDEX, digest='sha256:' + digest, size=len(content))])
    (layout / 'index.json').write_bytes(encoded(root))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix='nested-', dir=ROOT / '_build'))
    binary = args.binary.resolve()

    def run(*arguments, status=0):
        result = subprocess.run([str(binary), *map(str, arguments)], cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=120)
        if result.returncode != status:
            raise AssertionError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout

    source = directory / 'source'
    source.mkdir()
    (source / 'data').write_bytes(b'externally indexed image content')
    for arch in ('amd64', 'arm64'):
        specification = dict(schemaVersion=1, ref='demo', platform=dict(os='linux', architecture=arch),
                             layers=[dict(source=str(source), compression='none')], output=dict(layout=str(directory / arch)))
        path = directory / f'{arch}.json'
        path.write_bytes(encoded(specification))
        run('build', path)
    flat = directory / 'flat'
    run('merge', flat, directory / 'amd64', directory / 'arm64')
    tree = directory / 'tree'
    shutil.copytree(flat, tree)
    wrap(tree)
    wrap(tree)
    walk = json.loads(run('tree', tree))
    assert walk['complete'] and len(walk['images']) == 2
    assert all(len(image['index_path']) == 3 and len(image['ancestors']) == 2 for image in walk['images'])
    projected = directory / 'projected'
    run('flatten', tree, projected)
    assert observe(projected) == observe(flat)
    pinned = directory / 'pinned-projection'
    root_pin = 'sha256:' + hashlib.sha256((tree / 'index.json').read_bytes()).hexdigest()
    receipt = json.loads(run('flatten-pinned', tree, root_pin, pinned))
    assert receipt['source_index'] == root_pin
    assert receipt['projected_index'] == 'sha256:' + hashlib.sha256((pinned / 'index.json').read_bytes()).hexdigest()
    assert observe(pinned) == observe(flat)
    refused_pin = directory / 'refused-pin'
    run('flatten-pinned', tree, 'sha256:' + '0' * 64, refused_pin, status=5)
    assert not refused_pin.exists()
    selected = directory / 'selected'
    run('tree-select', tree, selected, 'linux', 'arm64')
    assert observe(selected) == observe(directory / 'arm64')
    unknown = directory / 'unknown'
    shutil.copytree(tree, unknown)
    index = json.loads((unknown / 'index.json').read_bytes())
    index['manifests'].append(dict(mediaType='application/example.unknown', digest='sha256:' + '0' * 64, size=1))
    (unknown / 'index.json').write_bytes(encoded(index))
    assert not json.loads(run('tree', unknown))['complete']
    refused = directory / 'refused'
    run('flatten', unknown, refused, status=4)
    assert not refused.exists()
    images_only = directory / 'images-only'
    run('flatten', unknown, images_only, '--images-only')
    assert observe(images_only) == observe(flat)
    corrupt = directory / 'corrupt'
    shutil.copytree(tree, corrupt)
    broken = json.loads((corrupt / 'index.json').read_bytes())
    broken['manifests'][0]['size'] += 1
    (corrupt / 'index.json').write_bytes(encoded(broken))
    run('tree', corrupt, status=5)
    deep = directory / 'deep'
    shutil.copytree(flat, deep)
    for _ in range(17):
        wrap(deep)
    run('tree', deep, status=5)
    report = dict(schema='moonoci.nested-consumer.v1', externally_built_index_levels=2,
                  images=2, projected_content_matches=True, explicit_selection=True,
                  unknown_reported=True, implicit_partial_projection_refused=True,
                  corrupt_size_refused=True, excessive_depth_refused=True,
                  pinned_projection_verified=True, wrong_root_pin_refused=True)
    (directory / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
