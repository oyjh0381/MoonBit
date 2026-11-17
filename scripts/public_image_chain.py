"""Pull a pinned public OCI image with ORAS and verify it offline with MoonOCI."""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from independent_layout import assert_storage_comparison, observe, verified_blob

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
    kinds = {'0': 'file', '1': 'hardlink', '2': 'symlink', '5': 'directory'}
    for path, expected in image['files'].items():
        actual = observed[path]
        assert actual['kind'] == kinds[expected['kind']], path
        assert actual['content_digest'] == (None if expected['sha256'] is None else
                                            'sha256:' + expected['sha256']), path
        for key in ('mode', 'uid', 'gid', 'layer_index', 'layer_digest', 'link_target'):
            assert actual[key] == expected[key], (path, key)
        assert int(actual['mtime']) == expected['mtime'], path
        assert int(actual['bytes']) == expected['bytes'], path

    blobs = layout / 'blobs' / 'sha256'
    original_manifest = json.loads((blobs / ALPINE_AMD64.split(':')[1]).read_bytes())
    original_config = json.loads((blobs / original_manifest['config']['digest'].split(':')[1]).read_bytes())
    imported = []
    imported_layer_descriptors = original_manifest['layers']
    for descriptor, diff_id in zip(original_manifest['layers'], original_config['rootfs']['diff_ids'], strict=True):
        assert descriptor['mediaType'] in ('application/vnd.oci.image.layer.v1.tar',
                                           'application/vnd.oci.image.layer.v1.tar+gzip')
        spec = dict(path=str(blobs / descriptor['digest'].split(':')[1]), diffId=diff_id)
        if descriptor['mediaType'].endswith('+gzip'):
            spec.update(encoding='gzip', blobDigest=descriptor['digest'])
        imported.append(dict(sourceTar=spec))
    overlay = work / 'overlay'
    overlay.mkdir()
    marker = 'moonoci-import-chain.txt'
    assert marker not in observed
    (overlay / marker).write_text('imported Alpine base', encoding='utf-8')
    recomposed = work / 'recomposed'
    build_spec = work / 'recomposed.json'
    build_spec.write_text(json.dumps(dict(
        schemaVersion=1, ref='recomposed', created='2026-01-01T00:00:00Z',
        layers=[*imported, dict(source=str(overlay))], output=dict(layout=str(recomposed)),
    )), encoding='utf-8')
    run(binary, 'build', build_spec)
    run(binary, 'verify', recomposed)
    new_index = json.loads((recomposed / 'index.json').read_bytes())
    new_blobs = recomposed / 'blobs' / 'sha256'
    new_manifest = json.loads((new_blobs / new_index['manifests'][0]['digest'].split(':')[1]).read_bytes())
    assert new_manifest['layers'][:-1] == original_manifest['layers']
    recomposed_files = observe(recomposed)['images'][0]['files']
    assert recomposed_files.pop(marker)['sha256'] == hashlib.sha256(b'imported Alpine base').hexdigest()
    assert recomposed_files == image['files']

    plain = work / 'alpine-uncompressed'
    report = json.loads(run(binary, 'transcode-image', projected, ALPINE_AMD64, 'none', plain))
    assert report['sourceManifest'] == ALPINE_AMD64
    assert report['convertedLayers'] == sum('gzip' in entry['mediaType'] for entry in imported_layer_descriptors)
    assert json.loads(run(binary, 'verify-store', plain))['valid']
    before_chain = json.loads(run(binary, 'layer-chain', projected, 'linux', 'amd64'))['layers']
    after_chain = json.loads(run(binary, 'layer-chain', plain, 'linux', 'amd64'))['layers']
    for before, after in zip(before_chain, after_chain, strict=True):
        assert before['diffId'] == after['diffId'] == after['blob']
        assert before['chainId'] == after['chainId']
        original_bytes = (projected / 'blobs/sha256' / before['blob'].split(':')[1]).read_bytes()
        plain_bytes = (plain / 'blobs/sha256' / after['blob'].split(':')[1]).read_bytes()
        assert plain_bytes == (gzip.decompress(original_bytes) if before['mediaType'].endswith('+gzip')
                               else original_bytes)
    plain_image, = observe(plain)['images']
    assert plain_image['platform'] == image['platform']
    for name, entry in image['files'].items():
        assert {k: v for k, v in entry.items() if k != 'layer_digest'} == {
            k: v for k, v in plain_image['files'][name].items() if k != 'layer_digest'}

    # Exercise actual DEFLATE on the uncompressed public layer, using the
    # preview pin to admit exactly the bytes that were reviewed.
    compact = work / 'alpine-deflate'
    plain_pin = report['resultManifest']
    policy = ('--gzip-level', '6', '--only-if-smaller', '--min-layer-savings', '1')
    preview = json.loads(run(binary, 'transcode-image', plain, plain_pin, 'gzip', compact,
                             *policy, '--dry-run'))
    assert not compact.exists()
    compact_receipt = json.loads(run(
        binary, 'transcode-image', plain, plain_pin, 'gzip', compact, *policy,
        '--expect-source-index', preview['sourceIndex'], '--expect-index', preview['resultIndex']))
    compact_pin = compact_receipt['resultManifest']
    migration = json.loads(run(
        binary, 'compare-image-storage', plain, plain_pin, compact, compact_pin,
        '--require-runtime-identity', '--expect-before-index', preview['sourceIndex'],
        '--expect-after-index', preview['resultIndex']))
    assert_storage_comparison(migration, plain, plain_pin, compact, compact_pin)
    compact_descriptor, = json.loads((compact / 'index.json').read_bytes())['manifests']
    compact_manifest = json.loads(verified_blob(compact, compact_descriptor))
    assert compact_manifest['config']['digest'] == original_manifest['config']['digest']
    for reference, converted in zip(after_chain, compact_manifest['layers'], strict=True):
        stored = verified_blob(compact, converted)
        tar = gzip.decompress(stored) if converted['mediaType'].endswith('+gzip') else stored
        assert tar == (plain / 'blobs' / 'sha256' / reference['blob'].split(':')[1]).read_bytes()
    assert compact_receipt['convertedLayers'] > 0
    assert int(compact_receipt['layerSavingsBytes']) == (
        int(migration['beforeLayerBytes']) - int(migration['afterLayerBytes']))

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
                  moonoci_semantic_verification=True, recomposed_pinned_base_layers=len(imported),
                  independently_transcoded_public_image=True,
                  deflate_storage_migration=dict(
                      source_layer_bytes=int(migration['beforeLayerBytes']),
                      result_layer_bytes=int(migration['afterLayerBytes']),
                      saved_layer_bytes=int(compact_receipt['layerSavingsBytes']),
                      candidate_blob_transfer_bytes=int(migration['newImageBlobBytes'])),
                  wrong_pin_and_corrupt_layer_refused=True, container_runtime_executed=False)
    (work / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
