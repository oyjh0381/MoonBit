"""Compare multilayer build and file provenance with CPython's OCI observer."""
import argparse
import gzip
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
        if tar_format == tarfile.GNU_FORMAT:
            linked = tarfile.TarInfo("./bin/tool-link")
            linked.type = tarfile.LNKTYPE
            linked.linkname = "./bin/tool"
            tar.addfile(linked)
    original = manifest["layers"][0]
    manifest["layers"] = [write(original, stream.getvalue())]
    config["rootfs"]["diff_ids"] = [manifest["layers"][0]["digest"]]
    config.pop("history", None)
    manifest["config"] = write(manifest["config"], json.dumps(config).encode())
    index["manifests"] = [write(index["manifests"][0], json.dumps(manifest).encode())]
    (target / "index.json").write_bytes(json.dumps(index).encode())


def import_external_layer(run, work, base, upper):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w", format=tarfile.PAX_FORMAT) as tar:
        whiteout = tarfile.TarInfo(".wh.keep")
        tar.addfile(whiteout)
        content = b"imported tool"
        original = tarfile.TarInfo("tool")
        original.size = len(content)
        original.mode = 0o750
        original.uid = 2097152
        tar.addfile(original, io.BytesIO(content))
        linked = tarfile.TarInfo("tool-copy")
        linked.type = tarfile.LNKTYPE
        linked.linkname = "tool"
        tar.addfile(linked)
    raw = stream.getvalue()
    raw_path = work / "external-layer.tar"
    raw_path.write_bytes(raw)
    gzip_path = work / "external-layer.tar.gz"
    # A nonzero producer timestamp demonstrates that the stored header survives.
    compressed = gzip.compress(raw, mtime=123456)
    gzip_path.write_bytes(compressed)
    diff_id = "sha256:" + hashlib.sha256(raw).hexdigest()
    blob_pin = "sha256:" + hashlib.sha256(compressed).hexdigest()
    configs = []
    chains = []
    for imported, storage, name in [
        (dict(sourceTar=dict(path=str(raw_path), diffId=diff_id)), raw, "raw"),
        (dict(sourceTar=dict(path=str(gzip_path), diffId=diff_id, blobDigest=blob_pin,
                             encoding="gzip")), compressed, "gzip"),
    ]:
        target = work / ("mixed-" + name)
        spec = work / ("mixed-" + name + ".json")
        layers = [dict(source=str(base)), imported, dict(source=str(upper))]
        spec.write_text(json.dumps(dict(schemaVersion=1, layers=layers,
                                        output=dict(layout=str(target)))), encoding="utf-8")
        run("build", spec)
        assert run("verify", target).startswith("valid: manifests=1")
        index = json.loads((target / "index.json").read_bytes())
        blobs = target / "blobs/sha256"
        manifest = json.loads((blobs / index["manifests"][0]["digest"].split(":")[1]).read_bytes())
        configs.append(manifest["config"]["digest"])
        stored = manifest["layers"][1]
        assert (blobs / stored["digest"].split(":")[1]).read_bytes() == storage
        config = json.loads((blobs / configs[-1].split(":")[1]).read_bytes())
        assert config["rootfs"]["diff_ids"][1] == diff_id
        report = json.loads(run("layer-chain", target, "linux", "amd64"))
        assert report["manifest"] == index["manifests"][0]["digest"]
        previous = None
        for row, descriptor, diff in zip(report["layers"], manifest["layers"],
                                         config["rootfs"]["diff_ids"], strict=True):
            previous = (diff if previous is None else
                        "sha256:" + hashlib.sha256((previous + " " + diff).encode("ascii")).hexdigest())
            assert row["blob"] == descriptor["digest"]
            assert row["diffId"] == diff and row["chainId"] == previous
        chains.append(report["layers"])
        expected = observe(target)["images"][0]["files"]
        actual = {item["path"]: item for item in
                  json.loads(run("files", target, "linux", "amd64"))["entries"]}
        assert set(actual) == set(expected) == {"app", "boot", "tool", "tool-copy"}
        for name, reference in expected.items():
            if reference["sha256"] is not None:
                assert actual[name]["content_digest"] == "sha256:" + reference["sha256"]
        assert actual["tool-copy"]["uid"] == 2097152
    assert configs[0] == configs[1]
    assert chains[0][1]["blob"] != chains[1][1]["blob"]
    assert [row["chainId"] for row in chains[0]] == [row["chainId"] for row in chains[1]]

    declined = work / "declined-layout"
    spec = work / "incorrect-layer-pin.json"
    spec.write_text(json.dumps(dict(schemaVersion=1, layers=[dict(
        sourceTar=dict(path=str(gzip_path), encoding="gzip", blobDigest=blob_pin,
                       diffId="sha256:" + "0" * 64))], output=dict(layout=str(declined)))),
        encoding="utf-8")
    try:
        run("build", spec)
    except subprocess.CalledProcessError as error:
        assert "DiffID" in error.stderr
    else:
        raise AssertionError("incorrect layer DiffID was accepted")
    assert not declined.exists()



def transcode_existing_image(run, work):
    source = work / "mixed-raw"
    expected = json.loads(run("layer-chain", source, "linux", "amd64"))
    manifest = expected["manifest"]
    wrong = work / "transcode-wrong"
    try:
        run("transcode-image", source, "sha256:" + "0" * 64, "gzip", wrong)
    except subprocess.CalledProcessError:
        assert not wrong.exists()
    else:
        raise AssertionError("bad manifest pin was accepted")

    encoded = work / "transcoded-gzip"
    preview = json.loads(run("transcode-image", source, manifest, "gzip", encoded, "--dry-run"))
    assert not preview["written"] and not encoded.exists()
    assert preview["sourceIndex"] == "sha256:" + hashlib.sha256((source / "index.json").read_bytes()).hexdigest()
    try:
        run("transcode-image", source, manifest, "gzip", encoded,
            "--expect-source-index", "sha256:" + "0" * 64)
    except subprocess.CalledProcessError as error:
        assert error.returncode == 5 and not encoded.exists()
    else:
        raise AssertionError("incorrect source index was accepted")
    try:
        run("transcode-image", source, manifest, "gzip", encoded, "--layers", "1",
            "--expect-index", preview["resultIndex"])
    except subprocess.CalledProcessError as error:
        assert error.returncode == 5 and not encoded.exists()
    else:
        raise AssertionError("changed transcode selection matched the preview")
    budget = int(preview["resultLayerBytes"])
    try:
        run("transcode-image", source, manifest, "gzip", encoded,
            "--max-layer-bytes", str(budget - 1))
    except subprocess.CalledProcessError as error:
        assert error.returncode == 5 and not encoded.exists()
    else:
        raise AssertionError("output exceeding the storage budget was accepted")
    receipt = json.loads(run("transcode-image", source, manifest, "gzip", encoded,
                             "--expect-index", preview["resultIndex"],
                             "--expect-source-index", preview["sourceIndex"],
                             "--max-layer-bytes", str(budget)))
    assert receipt["written"] and receipt["resultIndex"] == preview["resultIndex"]
    assert receipt["convertedLayers"] == len(expected["layers"])
    assert receipt["sourceManifest"] == manifest
    assert receipt["resultManifest"] != manifest
    assert run("verify", encoded).startswith("valid: manifests=1")
    compact = json.loads(run("layer-chain", encoded, "linux", "amd64"))
    assert compact["manifest"] == receipt["resultManifest"]
    original_files = observe(source)["images"][0]["files"]
    encoded_files = observe(encoded)["images"][0]["files"]
    # File provenance compares layer position, while stored layer digests change.
    for files in (original_files, encoded_files):
        for node in files.values():
            node.pop("layer_digest")
    assert original_files == encoded_files

    for before, after in zip(expected["layers"], compact["layers"], strict=True):
        assert before["diffId"] == after["diffId"] and before["chainId"] == after["chainId"]
        raw = (source / "blobs/sha256" / before["blob"].split(":")[1]).read_bytes()
        stored = (encoded / "blobs/sha256" / after["blob"].split(":")[1]).read_bytes()
        assert gzip.decompress(stored) == raw

    selected = work / "transcoded-selected"
    result = json.loads(run("transcode-image", source, manifest, "gzip", selected,
                            "--layers", "1"))
    assert result["convertedLayers"] == 1
    output = json.loads(run("layer-chain", selected, "linux", "amd64"))["layers"]
    assert output == [expected["layers"][0], compact["layers"][1], expected["layers"][2]]
    try:
        run("transcode-image", source, manifest, "gzip", wrong, "--layers", "1,1")
    except subprocess.CalledProcessError as error:
        assert error.returncode == 2 and not wrong.exists()
    else:
        raise AssertionError("ambiguous layer selection was accepted")

    decoded = work / "transcoded-back"
    restored = json.loads(run("transcode-image", encoded, compact["manifest"], "none", decoded))
    assert restored["resultManifest"] == manifest
    assert (decoded / "index.json").read_bytes() == (source / "index.json").read_bytes()
    repeat = work / "transcoded-no-op"
    unchanged = json.loads(run("transcode-image", encoded, compact["manifest"], "gzip", repeat))
    assert unchanged["convertedLayers"] == 0
    assert (repeat / "index.json").read_bytes() == (encoded / "index.json").read_bytes()



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
        expected_paths = {"bin", "bin/tool"}
        if tar_format == tarfile.GNU_FORMAT:
            expected_paths.add("bin/tool-link")
            linked = next(item for item in inventory if item["path"] == "bin/tool-link")
            oracle = files["bin/tool-link"]
            assert linked["kind"] == "hardlink" and linked["link_target"] == "bin/tool"
            assert linked["content_digest"] == "sha256:" + oracle["sha256"]
            assert linked["uid"] == oracle["uid"] == uid
        assert {item["path"] for item in inventory} == set(files) == expected_paths
        tool = next(entry for entry in inventory if entry["path"] == "bin/tool")
        assert tool["content_digest"] == "sha256:" + files["bin/tool"]["sha256"]
        assert tool["uid"] == files["bin/tool"]["uid"] == uid
        assert tool["gid"] == files["bin/tool"]["gid"] == gid
    hardlink_source = work / "hardlink-source"
    hardlink_source.mkdir()
    (hardlink_source / "z").write_bytes(b"original payload")
    hardlink_update = work / "hardlink-update"
    hardlink_update.mkdir()
    (hardlink_update / "z").write_bytes(b"new target")
    payload = dict(schemaVersion=1, layers=[
        dict(source=str(hardlink_source), hardlinks={"a": "b", "b": "z"},
             compression="gzip", metadata=dict(uid=47, mode=416)),
        dict(source=str(hardlink_update)),
    ])
    indexes = []
    for run_index in range(2):
        target = work / f"hardlink-layout-{run_index}"
        spec = work / f"hardlink-{run_index}.json"
        spec.write_text(json.dumps(dict(payload, output=dict(layout=str(target)))), encoding="utf-8")
        run("build", spec)
        indexes.append((target / "index.json").read_bytes())
        assert run("verify", target).startswith("valid: manifests=1")
        files = observe(target)["images"][0]["files"]
        assert set(files) == {"a", "b", "z"}
        for item in json.loads(run("files", target, "linux", "amd64"))["entries"]:
            source = files[item["path"]]
            assert item["content_digest"] == "sha256:" + source["sha256"]
            assert item["link_target"] == source["link_target"]
            assert item["mode"] == source["mode"] and item["uid"] == source["uid"]
            if item["path"] in {"a", "b"}:
                assert item["kind"] == "hardlink" and source["kind"] == "1"
                assert source["sha256"] == hashlib.sha256(b"original payload").hexdigest()
    assert indexes[0] == indexes[1]
    import_external_layer(run, work, base, reset)
    transcode_existing_image(run, work)
    print(json.dumps(dict(layer_counts=[2, 3], independently_verified_files=6,
                          deterministic_hardlinks=True,
                          same_path_whiteout=True, whole_root_opacity=True,
                          independent_tar_producer=True, independent_gnu_hardlink=True,
                          deterministic_pax_owners=True, pinned_tar_and_gzip_import=True,
                          compression_independent_chain_ids=True,
                          image_transcode_roundtrip=True)))


if __name__ == "__main__":
    main()
