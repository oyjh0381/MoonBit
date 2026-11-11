"""Package a compiled MoonBit module and independently recover it with ORAS."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG_TYPE = "application/vnd.wasm.config.v0+json"


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def read_blob(layout, descriptor):
    algorithm, encoded = descriptor["digest"].split(":")
    assert algorithm == "sha256"
    data = (layout / "blobs" / algorithm / encoded).read_bytes()
    assert digest(data) == descriptor["digest"]
    assert len(data) == descriptor["size"]
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--wasm", type=Path, required=True)
    parser.add_argument("--oras", type=Path, required=True)
    args = parser.parse_args()
    cli, source, oras = (path.resolve(strict=True) for path in (args.binary, args.wasm, args.oras))
    workspace = Path(tempfile.mkdtemp(prefix="wasm-artifact-", dir=ROOT / "_build"))
    expected = source.read_bytes()

    def run(*arguments, status=0):
        result = subprocess.run(list(map(str, arguments)), cwd=workspace,
                                capture_output=True, encoding="utf-8", timeout=60)
        if result.returncode != status:
            raise RuntimeError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout.strip()

    manifest_pin = run(cli, "wasm-pack", source, "fixture", "artifact")
    assert run(cli, "wasm-pack", source, "fixture", "rebuilt") == manifest_pin
    run(cli, "wasm-pack", source, "fixture", "artifact", status=3)
    artifact = workspace / "artifact"
    index_bytes = (artifact / "index.json").read_bytes()
    assert index_bytes == (workspace / "rebuilt" / "index.json").read_bytes()
    [advertised] = json.loads(index_bytes)["manifests"]
    assert advertised["digest"] == manifest_pin
    manifest = json.loads(read_blob(artifact, advertised))
    assert manifest["config"]["mediaType"] == CONFIG_TYPE
    [layer] = manifest["layers"]
    assert layer["mediaType"] == "application/wasm"
    assert layer["digest"] == digest(expected)
    assert read_blob(artifact, layer) == expected
    config = json.loads(read_blob(artifact, manifest["config"]))
    assert config == {"architecture": "wasm", "os": "wasip1", "layerDigests": [digest(expected)]}
    plan_arguments = ("registry-plan", "artifact", digest(index_bytes), "fixture",
                      "https://registry.example", "team/modules", "release")
    plan = json.loads(run(cli, *plan_arguments))
    assert plan["origin"] == "https://registry.example" and plan["tag"] == "release"
    assert plan["root"] == manifest_pin
    assert [item["digest"] for item in plan["blobs"]] == [manifest["config"]["digest"], layer["digest"]]
    assert [item["digest"] for item in plan["manifests"]] == [manifest_pin]
    plan_pin = plan.pop("plan_pin")
    assert plan_pin == digest(json.dumps(plan, separators=(",", ":"), ensure_ascii=False).encode())
    run(oras, "pull", "--oci-layout", "artifact:fixture", "--output", "consumer")
    assert (workspace / "consumer" / "module.wasm").read_bytes() == expected

    # ORAS builds a second manifest from its own config and payload input.
    (workspace / "payload.wasm").write_bytes(expected)
    (workspace / "config.json").write_text(json.dumps(config), encoding="utf-8")
    run(oras, "push", "--oci-layout", "external:module", "--config",
        "config.json:" + CONFIG_TYPE, "payload.wasm:application/wasm")
    external_index = (workspace / "external" / "index.json").read_bytes()
    external_pin = digest(external_index)
    observed = json.loads(run(cli, "wasm-inspect", "external", external_pin, "module"))
    assert observed["kind"] == "module"
    assert observed["layer"] == digest(expected) and observed["bytes"] == len(expected)
    assert observed["manifest"] != manifest_pin
    run(cli, "wasm-export", "external", digest(index_bytes), "module", "bad-pin.wasm", status=5)
    assert not (workspace / "bad-pin.wasm").exists()
    pending = workspace / "exported.wasm.moonoci-partial"
    pending.write_bytes(b"other producer")
    run(cli, "wasm-export", "external", external_pin, "module", "exported.wasm", status=3)
    assert pending.read_bytes() == b"other producer"
    pending.unlink()
    assert json.loads(run(cli, "wasm-export", "external", external_pin, "module",
                          "exported.wasm")) == observed
    assert (workspace / "exported.wasm").read_bytes() == expected

    (workspace / "invalid.wasm").write_bytes(b"\0asm\x01\0\0\0\x00\x01")
    run(cli, "wasm-pack", "invalid.wasm", "fixture", "invalid-layout", status=2)
    assert not (workspace / "invalid-layout").exists()
    result = dict(manifest=manifest_pin, module=digest(expected), bytes=len(expected),
                  oras_recovered_exact_module=True, consumed_oras_produced_layout=True,
                  publication_plan_verified=True,
                  reproducible=True)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
