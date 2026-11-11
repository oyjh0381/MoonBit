"""Independently inspect a rebased image and its byte-identical app layer."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from independent_layout import observe
from registry_publish_chain import run_zot

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def read_blob(layout, descriptor):
    data = (layout / "blobs/sha256" / descriptor["digest"][7:]).read_bytes()
    assert sha(data) == descriptor["digest"] and len(data) == descriptor["size"]
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--zot", type=Path)
    parser.add_argument("--oras", type=Path)
    args = parser.parse_args()
    if bool(args.zot) != bool(args.oras):
        parser.error("--zot and --oras must be supplied together")
    binary = args.binary.resolve(strict=True)
    directory = Path(tempfile.mkdtemp(prefix="rebase-", dir=ROOT / "_build"))

    def run(*arguments, status=0, executable=binary, environment=None):
        result = subprocess.run([str(executable), *map(str, arguments)], cwd=directory,
            capture_output=True, text=True, encoding="utf-8", timeout=120, env=environment)
        if result.returncode != status:
            raise RuntimeError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout

    def source(name, files):
        root = directory / name
        root.mkdir()
        for name, contents in files.items():
            (root / name).write_bytes(contents)
        return root

    def build(name, layers, config=None):
        result = directory / name
        spec = directory / (name + ".json")
        spec.write_text(json.dumps(dict(schemaVersion=1, ref=name, layers=layers,
            config=config or {}, output=dict(layout=str(result)))), encoding="utf-8")
        run("build", spec)
        return result

    old_files = source("old-files", {"base": b"version A", "obsolete": b"old"})
    app_files = source("app-files", {"app": b"deployable payload"})
    new_files = source("new-files", {"base": b"version B", "obsolete": b"updated"})
    new_patch = source("new-patch", {"patch": b"added base file"})
    old = build("old", [dict(source=str(old_files), compression="none")])
    application = build("app", [
        dict(source=str(old_files), compression="gzip"),
        dict(source=str(app_files), compression="none", remove=["obsolete"]),
    ], dict(entrypoint=["/app"], env={"APP_OPTION": "retained"}))
    new = build("new", [dict(source=str(path), compression="gzip") for path in (new_files, new_patch)])
    originals = [(layout / "index.json").read_bytes() for layout in (application, old, new)]
    descriptors = [json.loads(raw)["manifests"][0] for raw in originals]
    inputs = (application, old, new, *(descriptor["digest"] for descriptor in descriptors))
    plan = json.loads(run("rebase-plan", *inputs))
    assert plan["removedLayers"] == 1 and [layer["fromReplacement"] for layer in plan["layers"]] == [True, True, False]
    output = directory / "rebased"
    receipt = json.loads(run("rebase", *inputs, "candidate", output, "example.com/team/base:patched"))
    assert receipt["plan"] == plan and receipt["indexDigest"] == sha((output / "index.json").read_bytes())
    repeated = directory / "repeated"
    assert json.loads(run("rebase", *inputs, "candidate", repeated, "example.com/team/base:patched")) == receipt
    run("rebase", *inputs, "candidate", output, status=3)

    [app_desc, _, new_desc] = descriptors
    app_manifest = json.loads(read_blob(application, app_desc))
    new_manifest = json.loads(read_blob(new, new_desc))
    output_desc = json.loads((output / "index.json").read_bytes())["manifests"][0]
    output_manifest = json.loads(read_blob(output, output_desc))
    assert output_desc["digest"] == receipt["manifestDigest"]
    assert output_manifest["layers"] == new_manifest["layers"] + app_manifest["layers"][1:]
    assert read_blob(output, output_manifest["layers"][2]) == read_blob(application, app_manifest["layers"][1])
    assert output_manifest["annotations"]["org.opencontainers.image.base.digest"] == new_desc["digest"]
    app_config = json.loads(read_blob(application, app_manifest["config"]))
    result_config = json.loads(read_blob(output, output_manifest["config"]))
    assert result_config["config"] == app_config["config"]
    assert len(result_config["history"]) == 3
    independent = observe(output)["images"][0]["files"]
    assert set(independent) == {"app", "base", "patch"}
    assert independent["base"]["sha256"] == hashlib.sha256(b"version B").hexdigest()
    assert independent["app"]["sha256"] == hashlib.sha256(b"deployable payload").hexdigest()
    assert [(layout / "index.json").read_bytes() for layout in (application, old, new)] == originals
    invalid = directory / "bad-prefix"
    unrelated = build("unrelated", [dict(source=str(new_files), compression="none")])
    unrelated_pin = observe(unrelated)["images"][0]["manifest"]
    run("rebase", application, unrelated, new, app_desc["digest"], unrelated_pin,
        new_desc["digest"], "candidate", invalid, status=5)
    assert not invalid.exists()
    policy = dict(schemaVersion=1, baselineIndex=sha(originals[0]),
                  candidateIndex=receipt["indexDigest"],
                  requiredPlatforms=[{"os": "linux", "architecture": "amd64"}])
    policy_path = directory / "rollout-policy.json"
    policy_path.write_text(json.dumps(policy), encoding="utf-8")
    denied = json.loads(run("rollout-check", application, output, policy_path, status=5))
    [platform] = denied["platforms"]
    assert platform["unreviewedPaths"] == ["base", "patch"]
    assert platform["unreviewedFields"] == []
    policy["approvals"] = [dict(platform=policy["requiredPlatforms"][0],
        baselineManifest=app_desc["digest"], candidateManifest=receipt["manifestDigest"],
        paths=["base", "patch"])]
    policy_path.write_text(json.dumps(policy), encoding="utf-8")
    assert json.loads(run("rollout-check", application, output, policy_path))["allowed"]
    registry_checked = False
    if args.zot:
        environment = os.environ.copy()
        environment.pop("MOONOCI_REGISTRY_PUSH_TOKEN", None)
        empty_auth = directory / "empty-auth.json"
        empty_auth.write_bytes(b"{}")
        with run_zot(args.zot.resolve(strict=True), directory) as origin:
            destination = (output, receipt["indexDigest"], "candidate", origin, "team/app", "patched")
            publish = json.loads(run("registry-plan", *destination, "--allow-http"))
            assert publish["root"] == receipt["manifestDigest"]
            remote = json.loads(run("registry-publish", *destination, publish["plan_pin"],
                                    "--allow-http", environment=environment))
            assert remote["root"] == receipt["manifestDigest"] and remote["tag_written"]
            readback = directory / "published"
            address = origin.removeprefix("http://") + "/team/app:patched"
            run("cp", "--from-plain-http", "--from-registry-config", empty_auth,
                "--to-oci-layout", address, str(readback) + ":patched",
                executable=args.oras.resolve(strict=True), environment=environment)
            assert observe(readback)["images"][0]["files"] == independent
            registry_checked = True
    print(json.dumps(dict(
        manifest=receipt["manifestDigest"], preserved_app_layer=True,
        runtime_configuration_preserved=True, independent_files=len(independent),
        whiteout_preserved=True, reproducible=True, unrelated_prefix_blocked=True,
        approved_rollout=True, registry_readback=registry_checked,
    ), indent=2))


if __name__ == "__main__":
    main()
