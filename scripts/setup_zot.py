"""Install the checksum-pinned Zot Registry used by the publication consumer."""
import hashlib
import os
from pathlib import Path
import platform
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
VERSION = "2.1.23"
BINARIES = {
    "Linux": (
        "zot-linux-amd64-minimal",
        "8a6e77686bc0e7751766c49828cff6c66b115c854d350c9d936b855463f6c973",
        90837292,
        "zot",
    ),
    "Windows": (
        "zot-windows-amd64-minimal.exe",
        "d8b29c9cd9d68f46a338a2ae0533991415148587703ec3bd0f909c22604f7bed",
        83825664,
        "zot.exe",
    ),
}


def verify(path, expected, size):
    if path.stat().st_size != size:
        raise ValueError("Zot binary size differs from the pinned release")
    with path.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != expected:
            raise ValueError("Zot binary SHA-256 differs from the pinned release")


def main():
    if platform.machine().lower() not in ("amd64", "x86_64") or platform.system() not in BINARIES:
        raise SystemExit("This bootstrap supports Linux and Windows amd64")
    name, expected, size, filename = BINARIES[platform.system()]
    directory = ROOT / "_build" / "tools" / ("zot-" + VERSION)
    directory.mkdir(parents=True, exist_ok=True)
    binary = directory / filename
    if not binary.exists():
        url = f"https://github.com/project-zot/zot/releases/download/v{VERSION}/{name}"
        with tempfile.NamedTemporaryFile(dir=directory, delete=False) as stream:
            temporary = Path(stream.name)
        try:
            with urlopen(url, timeout=90) as response, temporary.open("wb") as output:
                count = 0
                while chunk := response.read(1024 * 1024):
                    count += len(chunk)
                    if count > size:
                        raise ValueError("Zot download exceeds its pinned size")
                    output.write(chunk)
            verify(temporary, expected, size)
            os.replace(temporary, binary)
        finally:
            temporary.unlink(missing_ok=True)
    verify(binary, expected, size)
    if os.name != "nt":
        binary.chmod(0o755)
    print(binary)


if __name__ == "__main__":
    main()
