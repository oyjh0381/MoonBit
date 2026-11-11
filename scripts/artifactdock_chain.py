"""Promote and re-admit a pinned OCI release across an ArtifactDock restart."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from registry_publish_chain import ROOT, REPO, build_layout, loopback_port, pin, run_loopback_registry

STATEMENT_MEDIA = "application/vnd.in-toto+json"
PREDICATE = "https://example.test/moonoci/build/v1"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--artifactdock", type=Path, required=True)
    args = parser.parse_args()
    binary, server = (path.resolve(strict=True) for path in (args.binary, args.artifactdock))
    work = Path(tempfile.mkdtemp(prefix="artifactdock-", dir=ROOT / "_build"))
    env = os.environ.copy()
    for key in ("MOONOCI_REGISTRY_TOKEN", "MOONOCI_REGISTRY_PUSH_TOKEN"):
        env.pop(key, None)

    def run(*arguments, status=0):
        proc = subprocess.run([str(binary), *map(str, arguments)], cwd=work, env=env,
                              capture_output=True, text=True, encoding="utf-8", timeout=90)
        if proc.returncode != status:
            raise RuntimeError((arguments, proc.returncode, proc.stdout, proc.stderr))
        return proc.stdout.strip()

    def launch(label):
        port = loopback_port()
        return run_loopback_registry(
            [server, "--root", work / "store", "--host", "127.0.0.1", "--port", port],
            work / (label + ".log"), port,
        )

    baseline, baseline_pin, root = build_layout(run, work)
    statement = work / "statement.json"
    statement.write_text(json.dumps({
        "_type": "https://in-toto.io/Statement/v1",
        "subject": [{"name": REPO, "digest": {"sha256": root.removeprefix("sha256:")}}],
        "predicateType": PREDICATE,
        "predicate": {"build": "interop-fixture"},
    }), encoding="utf-8")
    candidate = work / "candidate"
    evidence = run("artifact-attach", baseline, root, STATEMENT_MEDIA, STATEMENT_MEDIA,
                   statement, "build-evidence", candidate)
    policy = work / "rollout.json"
    policy.write_text(json.dumps(dict(
        schemaVersion=1, baselineIndex=baseline_pin,
        candidateIndex=pin((candidate / "index.json").read_bytes()),
        requiredPlatforms=[dict(os="linux", architecture=arch) for arch in ("amd64", "arm64")],
    )), encoding="utf-8")
    with launch("publisher") as origin:
        target = (baseline, candidate, policy, "candidate", origin, REPO, "reviewed", evidence)
        review = json.loads(run("registry-promote-bundle-plan", *target, "--allow-http"))
        receipt = json.loads(run("registry-promote-bundle", *target, review["promotionPin"], "--allow-http"))
        assert receipt["publication"]["root"] == root and receipt["publication"]["tag_written"]
        assert receipt["bundle"]["verifiedAttachments"] == 1

    reconstructed = work / "admitted"
    refused = work / "refused"
    with launch("consumer") as origin:
        source = (origin, REPO, "reviewed", root, root)
        requirements = ("--allow-http", "--require-artifact", STATEMENT_MEDIA, "--statement-digest", evidence)
        run("registry-admit", *source, refused, *requirements,
            "--statement-predicate", PREDICATE + "-incorrect", status=5)
        assert not refused.exists()
        run("registry-admit", *source, reconstructed, *requirements, "--statement-predicate", PREDICATE)

    def read_blobs(layout):
        return {entry.name: entry.read_bytes() for entry in (layout / "blobs/sha256").iterdir()}

    expected = read_blobs(candidate)
    recovered = read_blobs(reconstructed)
    assert recovered == expected
    assert all(pin(value) == "sha256:" + name for name, value in recovered.items())
    print(json.dumps(dict(root=root, statement_manifest=evidence, restored_objects=len(recovered),
                          persistent_restart=True, predicate_mismatch_refused=True,
                          admitted_bytes_identical=True), indent=2))


if __name__ == "__main__":
    main()
