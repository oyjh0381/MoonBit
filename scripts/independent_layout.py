"""Independent OCI image observation using only CPython standard library.
No MoonOCI implementation is imported; no archive member is extracted to disk.
"""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile


def observe(directory):
    root = Path(directory)
    assert json.loads((root / 'oci-layout').read_bytes())['imageLayoutVersion'] == '1.0.0'
    index = json.loads((root / 'index.json').read_bytes())
    assert index['schemaVersion'] == 2

    def blob(descriptor):
        algorithm, value = descriptor['digest'].split(':')
        assert algorithm == 'sha256' and len(value) == 64 and all(c in '0123456789abcdef' for c in value)
        path = root / 'blobs' / algorithm / value
        assert not path.is_symlink()
        data = path.read_bytes()
        assert len(data) == descriptor['size']
        assert hashlib.sha256(data).hexdigest() == value
        return data

    images = []
    for descriptor in index['manifests']:
        manifest = json.loads(blob(descriptor))
        assert manifest['schemaVersion'] == 2
        config = json.loads(blob(manifest['config']))
        if 'platform' in descriptor:
            assert all(config.get(key) == value for key, value in descriptor['platform'].items())
        assert config['rootfs']['type'] == 'layers'
        assert len(config['rootfs']['diff_ids']) == len(manifest['layers'])
        files = {}
        for layer, diff_id in zip(manifest['layers'], config['rootfs']['diff_ids']):
            data = blob(layer)
            if layer['mediaType'].endswith('+gzip'):
                # This verifier is for bounded, locally built demo images.
                # gzip decompression is not a hostile-input sandbox.
                data = gzip.decompress(data)
            else:
                assert layer['mediaType'] == 'application/vnd.oci.image.layer.v1.tar'
            assert 'sha256:' + hashlib.sha256(data).hexdigest() == diff_id
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
                additions = []
                for member in archive:
                    name = member.name.rstrip('/')
                    path = PurePosixPath(name)
                    assert not path.is_absolute() and '..' not in path.parts
                    if path.name == '.wh..wh..opq':
                        prefix = str(path.parent) + '/'
                        files = {p: v for p, v in files.items() if not p.startswith(prefix)}
                    elif path.name.startswith('.wh.'):
                        removed = str(path.parent / path.name[4:])
                        files = {p: v for p, v in files.items() if p != removed and not p.startswith(removed + '/')}
                    else:
                        stream = archive.extractfile(member) if member.isfile() else None
                        additions.append((name, dict(kind=member.type.decode(), mode=member.mode,
                            bytes=member.size, sha256=hashlib.sha256(stream.read()).hexdigest() if stream else None)))
                for name, metadata in additions:
                    files[name] = metadata
        images.append(dict(platform={k: config.get(k) for k in ('os','architecture','variant')},
                           manifest=descriptor['digest'], files=files))
    return dict(schema='moonoci.independent.v1', images=images)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('layout', type=Path)
    args = parser.parse_args()
    print(json.dumps(observe(args.layout), sort_keys=True))
