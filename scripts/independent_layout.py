"""Independent OCI image observation using only CPython standard library.
No MoonOCI implementation is imported; no archive member is extracted to disk.
"""
import argparse
import gzip
import hashlib
import io
import json
from itertools import zip_longest
from pathlib import Path, PurePosixPath
import tarfile


def apply_tar(files, data, layer_digest, layer_index):
    """Observe MoonOCI-supported file kinds; whiteouts affect lower layers only."""
    files = dict(files)
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
        additions = []
        seen = set()
        for member in archive:
            name = member.name.rstrip('/')
            path = PurePosixPath(name)
            assert name and not path.is_absolute() and '..' not in path.parts
            if str(path) == '.' and member.isdir():
                continue
            assert str(path) not in seen
            seen.add(str(path))
            assert member.isfile() or member.isdir() or member.issym() or member.islnk()
            if path.name.startswith('.wh.'):
                assert member.isfile() and member.size == 0
                if path.name == '.wh..wh..opq':
                    if path.parent == PurePosixPath('.'):
                        files.clear()
                    else:
                        prefix = str(path.parent) + '/'
                        files = {p: v for p, v in files.items() if not p.startswith(prefix)}
                else:
                    removed = str(path.parent / path.name[4:])
                    files = {p: v for p, v in files.items() if p != removed and not p.startswith(removed + '/')}
            else:
                stream = archive.extractfile(member) if member.isfile() or member.islnk() else None
                payload = stream.read() if stream is not None else None
                additions.append((str(path), dict(kind=member.type.decode(), mode=member.mode,
                    bytes=len(payload) if payload is not None else member.size,
                    sha256=hashlib.sha256(payload).hexdigest() if payload is not None else None,
                    uid=member.uid, gid=member.gid, mtime=member.mtime,
                    link_target=member.linkname if member.issym() or member.islnk() else None,
                    layer_digest=layer_digest, layer_index=layer_index)))
        hardlink_type = tarfile.LNKTYPE.decode()
        if not any(row["kind"] == hardlink_type for _, row in additions):
            additions.sort()
        for name, metadata in additions:
            if metadata["kind"] == hardlink_type:
                source = files[str(PurePosixPath(metadata["link_target"]))]
                assert metadata["sha256"] == source["sha256"]
                for key in ("mode", "uid", "gid", "mtime"):
                    metadata[key] = source[key]
            if metadata['kind'] != tarfile.DIRTYPE.decode():
                files = {p: v for p, v in files.items() if p != name and not p.startswith(name + '/')}
            files[name] = metadata
    return files


def observe(directory):
    root = Path(directory)
    assert json.loads((root / 'oci-layout').read_bytes())['imageLayoutVersion'] == '1.0.0'
    index = json.loads((root / 'index.json').read_bytes())
    assert index['schemaVersion'] == 2

    images = []
    for descriptor in index['manifests']:
        manifest = json.loads(verified_blob(root, descriptor))
        assert manifest['schemaVersion'] == 2
        config = json.loads(verified_blob(root, manifest['config']))
        if 'platform' in descriptor:
            assert all(config.get(key) == value for key, value in descriptor['platform'].items())
        assert config['rootfs']['type'] == 'layers'
        assert len(config['rootfs']['diff_ids']) == len(manifest['layers'])
        files = {}
        for layer_index, (layer, diff_id) in enumerate(zip(manifest['layers'], config['rootfs']['diff_ids'])):
            data = verified_blob(root, layer)
            if layer['mediaType'].endswith('+gzip'):
                # This verifier is for bounded, locally built demo images.
                # gzip decompression is not a hostile-input sandbox.
                data = gzip.decompress(data)
            else:
                assert layer['mediaType'] == 'application/vnd.oci.image.layer.v1.tar'
            assert 'sha256:' + hashlib.sha256(data).hexdigest() == diff_id
            files = apply_tar(files, data, layer['digest'], layer_index)
        images.append(dict(platform={k: config.get(k) for k in ('os','architecture','variant')},
                           manifest=descriptor['digest'], files=files))
    return dict(schema='moonoci.independent.v1', images=images)


def verified_blob(root, descriptor):
    algorithm, value = descriptor['digest'].split(':')
    assert algorithm == 'sha256' and len(value) == 64 and all(c in '0123456789abcdef' for c in value)
    path = root / 'blobs' / algorithm / value
    assert not path.is_symlink()
    data = path.read_bytes()
    assert len(data) == descriptor['size']
    assert hashlib.sha256(data).hexdigest() == value
    return data


def image_storage(root, manifest_pin):
    """Read physical storage costs independently from a fixture's OCI blobs."""
    index_bytes = (root / 'index.json').read_bytes()
    descriptor, = (entry for entry in json.loads(index_bytes)['manifests']
                   if entry['digest'] == manifest_pin)
    manifest = json.loads(verified_blob(root, descriptor))
    config = json.loads(verified_blob(root, manifest['config']))
    layers = {entry['digest']: len(verified_blob(root, entry)) for entry in manifest['layers']}
    blobs = layers | {entry['digest']: len(verified_blob(root, entry))
                      for entry in (descriptor, manifest['config'])}
    return (layers, blobs, config['rootfs']['diff_ids'], manifest['config']['digest'],
            'sha256:' + hashlib.sha256(index_bytes).hexdigest())


def assert_storage_comparison(report, before, before_pin, after, after_pin):
    before_layers, before_blobs, before_ids, before_config, before_index = image_storage(before, before_pin)
    after_layers, after_blobs, after_ids, after_config, after_index = image_storage(after, after_pin)
    difference = next((dict(position=offset, beforeDiffId=left, afterDiffId=right)
                       for offset, (left, right) in enumerate(zip_longest(before_ids, after_ids))
                       if left != right), None)
    assert report['schema'] == 'moonoci.image-storage-comparison.v1'
    assert report['beforeManifest'] == before_pin and report['afterManifest'] == after_pin
    assert report['beforeIndex'] == before_index and report['afterIndex'] == after_index
    assert report['beforeConfig'] == before_config and report['afterConfig'] == after_config
    assert report['firstLayerDifference'] == difference
    assert report['preservesRuntimeIdentity'] == (before_config == after_config and difference is None)
    assert int(report['beforeLayerBytes']) == sum(before_layers.values())
    assert int(report['afterLayerBytes']) == sum(after_layers.values())
    assert report['newLayerCount'] == len(after_layers.keys() - before_layers.keys())
    assert int(report['newLayerBytes']) == sum(after_layers[key] for key in after_layers.keys() - before_layers.keys())
    assert int(report['beforeImageBlobBytes']) == sum(before_blobs.values())
    assert int(report['afterImageBlobBytes']) == sum(after_blobs.values())
    assert int(report['newImageBlobBytes']) == sum(after_blobs[key] for key in after_blobs.keys() - before_blobs.keys())


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('layout', type=Path)
    args = parser.parse_args()
    print(json.dumps(observe(args.layout), sort_keys=True))
