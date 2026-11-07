"""Pull a pinned public OCI image with ORAS and verify it offline with MoonOCI."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from independent_layout import observe

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = 'registry-1.docker.io/library/alpine'
ALPINE_AMD64 = 'sha256:029a752048e32e843bd6defe3841186fb8d19a28dae8ec287f433bb9d6d1ad85'


def sha256(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--oras', type=Path, help='download the pinned manifest using ORAS')
    source.add_argument('--layout', type=Path, help='recheck a previously downloaded layout')
    args = parser.parse_args()
    binary = args.binary.resolve()
    work = Path(tempfile.mkdtemp(prefix='public-alpine-', dir=ROOT / '_build'))

    def run(exe, *arguments, status=0):
        result = subprocess.run([str(exe), *map(str, arguments)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=180)
        if result.returncode != status:
            raise RuntimeError((exe.name, result.returncode, result.stdout, result.stderr))
        return result.stdout.strip()

    if args.oras:
        config = work / 'empty-auth.json'
        config.write_bytes(b'{"auths":{}}')
        layout = work / 'alpine'
        run(args.oras.resolve(), 'cp', '--from-registry-config', config, '--to-oci-layout',
            REPOSITORY + '@' + ALPINE_AMD64, str(layout) + ':alpine')
    else:
        layout = args.layout.resolve()
    # The digest is fixed independently of both the response and the local wrapper.
    image, = observe(layout)['images']
    assert image['manifest'] == ALPINE_AMD64
    assert image['platform'] == {'os': 'linux', 'architecture': 'amd64', 'variant': None}
    assert json.loads(run(binary, 'verify-store', layout))['valid']
    original_index = (layout / 'index.json').read_bytes()
    projected = work / 'projected'
    run(binary, 'flatten-pinned', layout, sha256(original_index), projected, '--images-only')
    assert observe(projected)['images'] == [image]
    entries = json.loads(run(binary, 'files', projected, 'linux', 'amd64'))['entries']
    observed = {item['path']: item for item in entries}
    assert len(entries) == len(observed) == len(image['files'])
    kinds = {'0': 'file', '2': 'symlink', '5': 'directory'}
    for path, expected in image['files'].items():
        actual = observed[path]
        assert actual['kind'] == kinds[expected['kind']], path
        assert actual['content_digest'] == (None if expected['sha256'] is None else
                                            'sha256:' + expected['sha256']), path
        for key in ('mode', 'uid', 'gid', 'layer_index', 'layer_digest', 'link_target'):
            assert actual[key] == expected[key], (path, key)
        assert int(actual['mtime']) == expected['mtime'], path
        assert int(actual['bytes']) == expected['bytes'], path

    bad_pin_output = work / 'wrong-pin'
    run(binary, 'flatten-pinned', layout, 'sha256:' + '0' * 64, bad_pin_output, '--images-only', status=5)
    assert not bad_pin_output.exists()
    damaged = work / 'damaged'
    shutil.copytree(layout, damaged, copy_function=shutil.copyfile)
    digest = next(iter(image['files'].values()))['layer_digest']
    layer = damaged / 'blobs' / 'sha256' / digest.split(':', 1)[1]
    with layer.open('r+b') as stream:
        original = stream.read(1)
        stream.seek(0)
        stream.write(bytes([original[0] ^ 1]))
    rejected = json.loads(run(binary, 'verify-store', damaged, status=5))
    assert not rejected['valid']
    assert (layout / 'index.json').read_bytes() == original_index

    report = dict(schema='moonoci.public-image-consumer.v1', registry=REPOSITORY,
                  manifest=ALPINE_AMD64, platform='linux/amd64',
                  matching_inventory_entries=len(entries),
                  kinds=dict(Counter(item['kind'] for item in entries)),
                  absolute_symlinks=sum((item['link_target'] or '').startswith('/') for item in entries),
                  acquisition='oras-registry' if args.oras else 'existing-layout',
                  moonoci_semantic_verification=True,
                  wrong_pin_and_corrupt_layer_refused=True, container_runtime_executed=False)
    (work / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
