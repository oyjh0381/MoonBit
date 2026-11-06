"""Small literal regression cases for the development-only CPython observer."""
import io
import tarfile

from independent_layout import apply_tar


def archive(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w') as output:
        for name, data in entries:
            member = tarfile.TarInfo(name)
            member.size = len(data)
            output.addfile(member, io.BytesIO(data))
    return stream.getvalue()


def main():
    prior = {'old': {'kind': '0'}, 'dir': {'kind': '5'}, 'dir/old': {'kind': '0'}, 'keep': {'kind': '0'}}
    root = apply_tar(prior, archive([('new', b'new'), ('.wh..wh..opq', b'')]), 'layer', 1)
    assert set(root) == {'new'}  # root opaque marker applies only to inherited files
    child = apply_tar(prior, archive([('dir/new', b'new'), ('dir/.wh..wh..opq', b'')]), 'layer', 1)
    assert set(child) == {'old', 'dir', 'dir/new', 'keep'}
    replaced = apply_tar(prior, archive([('dir', b'file')]), 'layer', 1)
    assert 'dir/old' not in replaced and replaced['dir']['kind'] == '0'
    removed = apply_tar(prior, archive([('.wh.dir', b'')]), 'layer', 1)
    assert set(removed) == {'old', 'keep'}
    assert set(prior) == {'old', 'dir', 'dir/old', 'keep'}
    print('Independent layer observer: 4 literal transition cases passed')


if __name__ == '__main__':
    main()
