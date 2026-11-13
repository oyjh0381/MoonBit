"""Compare multilayer build and file provenance with CPython's OCI observer."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import tarfile

from independent_layout import observe
from registry_publish_chain import ROOT


def external_tar_layout(source, target, tar_format):
    """Create a one-layer image whose tar was produced by CPython."""
    (target / "blobs/sha256").mkdir(parents=True)
    (target / "oci-layout").write_bytes((source / "oci-layout").read_bytes())
    index = json.loads((source / "index.json").read_bytes())

    def read(descriptor):
        return json.loads((source / "blobs/sha256" / descriptor["digest"].split(":")[1]).read_bytes())

    def write(descriptor, data):
        digest = hashlib.sha256(data).hexdigest()
        (target / "blobs/sha256" / digest).write_bytes(data)
        return {**descriptor, "digest": "sha256:" + digest, "size": len(data)}

    manifest = read(index["manifests"][0])
    config = read(manifest["config"])
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tar_format) as tar:
        for name in (".", "./bin"):
            directory = tarfile.TarInfo(name)
            directory.type = tarfile.DIRTYPE
            directory.mode = 0o755
            tar.addfile(directory)
        payload = b"external tar content"
        member = tarfile.TarInfo("./bin/tool")
        member.size = len(payload)
        member.mode = 0o755
        if tar_format == tarfile.GNU_FORMAT:
            member.uid = 2097152
            member.gid = 2097153
        tar.addfile(member, io.BytesIO(payload))
    original = manifest["layers"][0]
    manifest["layers"] = [write(original, stream.getvalue())]
    config["rootfs"]["diff_ids"] = [manifest["layers"][0]["digest"]]
    config.pop("history", None)
    manifest["config"] = write(manifest["config"], json.dumps(config).encode())
    index["manifests"] = [write(index["manifests"][0], json.dumps(manifest).encode())]
    (target / "index.json").write_bytes(json.dumps(index).encode())


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
        dict(source=str(reset), opaque=["/"], metadata=dict(uid=2147483647, gid=2097152)),
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
            if count == 3:
                assert entry["uid"] == 2147483647 and entry["gid"] == 2097152
            assert all(entry[key] == oracle[key] for key in ("layer_digest", "layer_index", "mode", "uid", "gid"))
    for label, tar_format, uid, gid in [("ustar", tarfile.USTAR_FORMAT, 0, 0),
                                       ("gnu", tarfile.GNU_FORMAT, 2097152, 2097153)]:
        external = work / label
        external_tar_layout(work / "layout-2", external, tar_format)
        assert run("verify", external).startswith("valid: manifests=1")
        inventory = json.loads(run("files", external, "linux", "amd64"))["entries"]
        files = observe(external)["images"][0]["files"]
        assert {item["path"] for item in inventory} == set(files) == {"bin", "bin/tool"}
        tool = next(entry for entry in inventory if entry["path"] == "bin/tool")
        assert tool["content_digest"] == "sha256:" + files["bin/tool"]["sha256"]
        assert tool["uid"] == files["bin/tool"]["uid"] == uid
        assert tool["gid"] == files["bin/tool"]["gid"] == gid
    print(json.dumps(dict(layer_counts=[2, 3], independently_verified_files=6,
                          same_path_whiteout=True, whole_root_opacity=True,
                          independent_tar_producer=True, deterministic_pax_owners=True)))


if __name__ == "__main__":
    main()
