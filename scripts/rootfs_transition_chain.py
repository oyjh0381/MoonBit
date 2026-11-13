"""Compare multilayer build and file provenance with CPython's OCI observer."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from independent_layout import observe
from registry_publish_chain import ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix="rootfs-transitions-", dir=ROOT / "_build"))

    def run(*arguments):
        return subprocess.run([str(binary), *map(str, arguments)], cwd=work, check=True,
                              capture_output=True, text=True, encoding="utf-8", timeout=90).stdout

    base, replace, reset = [work / name for name in ("base", "replace", "reset")]
    (base / "app").mkdir(parents=True)
    (base / "app" / "obsolete").write_bytes(b"old directory entry")
    (base / "keep").write_bytes(b"keep")
    replace.mkdir()
    (replace / "app").write_bytes(b"replacement executable")
    reset.mkdir()
    (reset / "app").write_bytes(b"fresh after opacity")
    (reset / "boot").write_bytes(b"boot")
    layers = [
        dict(source=str(base)),
        dict(source=str(replace), remove=["/app"], compression="gzip"),
        dict(source=str(reset), opaque=["/"]),
    ]
    for count, expected_paths in [(2, {"app", "keep"}), (3, {"app", "boot"})]:
        target = work / f"layout-{count}"
        spec = work / f"build-{count}.json"
        spec.write_text(json.dumps(dict(schemaVersion=1, layers=layers[:count],
                                       output=dict(layout=str(target)))), encoding="utf-8")
        run("build", spec)
        assert run("verify", target).startswith("valid: manifests=1")
        inventory = json.loads(run("files", target, "linux", "amd64"))["entries"]
        expected = observe(target)["images"][0]["files"]
        assert set(expected) == expected_paths == {entry["path"] for entry in inventory}
        for entry in inventory:
            oracle = expected[entry["path"]]
            assert entry["kind"] == "file" and oracle["kind"] == "0"
            assert entry["content_digest"] == "sha256:" + oracle["sha256"]
            assert int(entry["bytes"]) == oracle["bytes"]
            assert all(entry[key] == oracle[key] for key in ("layer_digest", "layer_index", "mode", "uid", "gid"))
    print(json.dumps(dict(layer_counts=[2, 3], independently_verified_files=4,
                          same_path_whiteout=True, whole_root_opacity=True)))


if __name__ == "__main__":
    main()
