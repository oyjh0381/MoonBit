"""Link a C consumer against the actual MoonBit Native static archive."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def pin(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    args = parser.parse_args()
    archive = args.archive.resolve(strict=True)
    moon = shutil.which("moon")
    if moon is None:
        raise SystemExit("moon must be on PATH")
    installation = Path(os.environ["MOON_HOME"]) if os.environ.get("MOON_HOME") else Path(moon).parent.parent
    include = installation / "include"
    source = ROOT / "examples/c-host/verify.c"
    api = ROOT / "adapter/chost"
    work = Path(tempfile.mkdtemp(prefix="c-host-", dir=ROOT / "_build"))
    executable = work / ("verify.exe" if os.name == "nt" else "verify")
    if os.name == "nt":
        if shutil.which("cl") is None:
            raise SystemExit("Use an MSVC Developer Command Prompt to link the C host")
        compile_args = ["cl", "/nologo", "/W4", "/WX", "/I" + str(include),
                        "/I" + str(api), str(source), str(archive), "/Fe:" + str(executable)]
    else:
        compile_args = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-I", str(include), "-I", str(api), str(source), str(archive),
                        "-lm", "-o", str(executable)]
    subprocess.run(compile_args, cwd=work, check=True, timeout=120)

    def verify(name, data, kind, status, digest=None):
        path = work / name
        path.write_bytes(data)
        result = subprocess.run([str(executable), kind, str(path), digest or pin(data)],
            cwd=work, capture_output=True, text=True, encoding="utf-8", timeout=30)
        assert result.returncode == status, (result.returncode, result.stdout, result.stderr)
        assert f"moonoci C ABI 1 status={status}" in result.stdout

    index = b'{"schemaVersion":2,"manifests":[]}'
    manifest = json.dumps(dict(schemaVersion=2, config=dict(
        mediaType="application/vnd.oci.image.config.v1+json",
        digest=pin(b"{}"), size=2), layers=[])).encode()
    verify("index.json", index, "index", 0)
    verify("manifest.json", manifest, "manifest", 0)
    verify("binary", b"\0\xffbinary", "blob", 0)
    verify("empty", b"", "blob", 0)
    verify("corrupt.json", index + b" ", "index", 3, pin(index))
    verify("bad-version.json", b'{"schemaVersion":1,"manifests":[]}', "index", 4)
    verify("bad-json.json", b"{", "manifest", 4)
    verify("bad-pin.json", index, "index", 2, "sha256:" + "z" * 64)
    print(json.dumps({"c_abi": 1, "cases": 8, "linked_static_archive": True}))


if __name__ == "__main__":
    main()
