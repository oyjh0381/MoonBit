"""Install an integrity-pinned, development-only ORAS binary under ignored _build.
Official ORAS v1.3.6 release checksums; no admin rights or global PATH mutation.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '1.3.6'
PACKAGES = {
    'windows_amd64': ('zip', 'ec3d19f386d5d2f0892288772d7b242475a05332aafa64b6773378ca771d76d3'),
    'linux_amd64': ('tar.gz', '66fb0ad7206f3f6fa77ed5b552049d364ccf4b50b1684554f731f76302b52ca0'),
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--archive', type=Path, help='reuse a downloaded official archive; checksum is still required')
    args = parser.parse_args()
    machine = platform.machine().lower()
    if machine not in ('amd64', 'x86_64'):
        parser.error('this bootstrap supports Windows/Linux amd64; install ORAS manually for other architectures')
    key = platform.system().lower() + '_amd64'
    if key not in PACKAGES:
        parser.error('unsupported bootstrap OS')
    extension, expected = PACKAGES[key]
    filename = f'oras_{VERSION}_{key}.{extension}'
    directory = ROOT / '_build' / 'tools' / ('oras-' + VERSION) / key
    directory.mkdir(parents=True, exist_ok=True)
    archive = args.archive.resolve() if args.archive else directory / filename
    if not args.archive:
        url = f'https://github.com/oras-project/oras/releases/download/v{VERSION}/{filename}'
        with urllib.request.urlopen(url, timeout=60) as response:
            with tempfile.NamedTemporaryFile(dir=directory, delete=False) as output:
                temporary = Path(output.name)
                size = 0
                while chunk := response.read(65536):
                    size += len(chunk)
                    if size > 16 * 1024 * 1024:
                        raise ValueError('ORAS archive exceeds download bound')
                    output.write(chunk)
        os.replace(temporary, archive)
    data = archive.read_bytes()
    if len(data) > 16 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError('official ORAS archive checksum mismatch')
    binary_name = 'oras.exe' if key.startswith('windows') else 'oras'
    # Read exactly the expected regular binary member; never extract archive paths.
    if extension == 'zip':
        with zipfile.ZipFile(io.BytesIO(data)) as package:
            info = package.getinfo(binary_name)
            if info.file_size > 128 * 1024 * 1024:
                raise ValueError('ORAS binary exceeds extraction bound')
            content = package.read(info)
    else:
        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as package:
            info = package.getmember(binary_name)
            if not info.isfile() or info.size > 128 * 1024 * 1024:
                raise ValueError('ORAS binary member invalid')
            content = package.extractfile(info).read()
    binary = directory / binary_name
    if not binary.exists() or binary.read_bytes() != content:
        with tempfile.NamedTemporaryFile(dir=directory, delete=False) as output:
            temporary = Path(output.name)
            output.write(content)
        os.replace(temporary, binary)
    if os.name != 'nt':
        binary.chmod(0o755)
    version = subprocess.check_output([str(binary), 'version'], text=True, encoding='utf-8', timeout=30).strip()
    if VERSION not in version:
        raise ValueError('unexpected ORAS version output')
    report = dict(version=VERSION, binary=str(binary), archive_sha256=expected, platform=key, version_output=version)
    (directory / 'install.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
