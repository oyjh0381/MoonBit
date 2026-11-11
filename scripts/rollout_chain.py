"""Verify the Native rollout gate with independently observed OCI layouts."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from independent_layout import observe

ROOT = Path(__file__).resolve().parents[1]
AMD = {"os": "linux", "architecture": "amd64"}
ARM = {"os": "linux", "architecture": "arm64", "variant": "v8"}


def pin(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix="rollout-", dir=ROOT / "_build"))

    def run(*arguments, status=0):
        result = subprocess.run([str(binary), *map(str, arguments)], cwd=work,
                                capture_output=True, text=True, encoding="utf-8", timeout=120)
        if result.returncode != status:
            raise RuntimeError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout

    def build(name, platform, data, env):
        root = work / (name + "-root")
        root.mkdir()
        (root / "app").write_bytes(data)
        output = work / name
        spec = work / (name + ".json")
        spec.write_bytes(encoded(dict(
            schemaVersion=1, ref=name, platform=platform,
            layers=[dict(source=str(root), compression="none")],
            config=dict(env=env), output=dict(layout=str(output)),
        )))
        run("build", spec)
        return output

    old = build("baseline-amd", AMD, b"same size A", {"ROLLOUT_SETTING": "prior-value"})
    updated = build("candidate-amd", AMD, b"same size B", {"ROLLOUT_SETTING": "private-new-value"})
    arm = build("stable-arm", ARM, b"arm unchanged", {})
    baseline, candidate = work / "baseline", work / "candidate"
    run("merge", baseline, old, arm)
    run("merge", candidate, updated, arm)
    before = observe(old)["images"][0]
    after = observe(updated)["images"][0]
    assert before["files"]["app"]["sha256"] == hashlib.sha256(b"same size A").hexdigest()
    assert after["files"]["app"]["sha256"] == hashlib.sha256(b"same size B").hexdigest()

    # Wrap the flat baseline in a nested index while keeping the original bytes.
    inner = (baseline / "index.json").read_bytes()
    inner_pin = pin(inner)
    media = "application/vnd.oci.image.index.v1+json"
    (baseline / "blobs/sha256" / inner_pin[7:]).write_bytes(inner)
    (baseline / "index.json").write_bytes(encoded(dict(
        schemaVersion=2, mediaType=media,
        manifests=[dict(digest=inner_pin, mediaType=media, size=len(inner))],
    )))
    left = pin((baseline / "index.json").read_bytes())
    right = pin((candidate / "index.json").read_bytes())
    policy = dict(schemaVersion=1, baselineIndex=left, candidateIndex=right,
                  requiredPlatforms=[AMD, ARM])
    document = work / "policy.json"

    def check(base, target, policy_value, status=0):
        document.write_bytes(encoded(policy_value))
        result = run("rollout-check", base, target, document, status=status)
        assert "private-new-value" not in result
        return json.loads(result)

    report = check(baseline, candidate, policy, status=5)
    amd, stable = report["platforms"]
    assert not report["allowed"] and stable["transition"] == "unchanged" and stable["allowed"]
    assert amd["transition"] == "updated"
    assert amd["baseline"] == [before["manifest"]] and amd["candidate"] == [after["manifest"]]
    assert amd["files"] == {"added": 0, "removed": 0, "modified": 1}
    assert amd["unreviewedPaths"] == ["app"] and amd["unreviewedFields"] == ["config.Env"]
    approval = dict(platform=AMD, baselineManifest=before["manifest"],
                    candidateManifest=after["manifest"], paths=["app"], fields=["config.Env"])
    assert check(baseline, candidate, {**policy, "approvals": [approval]})["allowed"]
    wrong = {**approval, "candidateManifest": before["manifest"]}
    document.write_bytes(encoded({**policy, "approvals": [wrong]}))
    assert not run("rollout-check", baseline, candidate, document, status=5)

    missing_pin = pin((updated / "index.json").read_bytes())
    missing = check(baseline, updated, {**policy, "candidateIndex": missing_pin}, status=5)
    assert missing["platforms"][1]["transition"] == "removed"
    assert check(candidate, candidate, {**policy, "baselineIndex": right})["allowed"]

    # Independently build an ambiguous index by appending the old amd64 descriptor.
    root = json.loads((candidate / "index.json").read_bytes())
    old_index = json.loads((old / "index.json").read_bytes())
    root["manifests"].extend(old_index["manifests"])
    for blob in (old / "blobs/sha256").iterdir():
        target = candidate / "blobs/sha256" / blob.name
        if not target.exists():
            target.write_bytes(blob.read_bytes())
    ambiguous_index = encoded(root)
    (candidate / "index.json").write_bytes(ambiguous_index)
    result = check(baseline, candidate, {**policy, "candidateIndex": pin(ambiguous_index)}, status=5)
    assert result["platforms"][0]["transition"] == "ambiguous"
    assert sorted(result["platforms"][0]["candidate"]) == sorted([before["manifest"], after["manifest"]])
    print(json.dumps(dict(
        required_platforms=2, independent_content_match=True,
        nested_baseline=True, reviewed_update=True, ambiguous_blocked=True,
        removed_platform_blocked=True, stale_approval_blocked=True,
        unchanged_allowed=True,
    ), indent=2))


if __name__ == "__main__":
    main()
