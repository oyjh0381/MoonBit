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
        lock = review["bundle"]["referrerLock"]
        lock_path = work / "reviewed-referrers.json"
        lock_path.write_bytes(lock["document"].encode("utf-8"))
        assert pin(lock_path.read_bytes()) == lock["pin"]
        assert json.loads(lock["document"])["attachments"] == [evidence]
        lock_args = ("--referrer-lock", lock_path, "--referrer-lock-pin", lock["pin"])
        receipt = json.loads(run("registry-promote-bundle", *target, review["promotionPin"], "--allow-http"))
        assert receipt["publication"]["root"] == root and receipt["publication"]["tag_written"]
        assert receipt["bundle"]["verifiedAttachments"] == 1
        mirror = REPO + "-mirror"
        mirror_target = (baseline, candidate, policy, "candidate", origin, mirror, "reviewed", evidence)
        mount = ("--allow-http", "--mount-from", REPO)
        mirror_review = json.loads(run("registry-promote-bundle-plan", *mirror_target, *mount))
        mirror_receipt = json.loads(run("registry-promote-bundle", *mirror_target,
                                        mirror_review["promotionPin"], *mount))
        mirrored = mirror_receipt["publication"]
        assert mirrored["uploaded_blobs"] == 0 and mirrored["mounted_blobs"] == 5
        assert int(mirrored["mounted_bytes"]) > 0 and mirrored["tag_written"]
        exact = json.loads(run("registry-bundle", origin, REPO, "reviewed", root, root,
                               work / "exact-referrers", "--allow-http",
                               *lock_args, "--exact-referrers"))
        assert exact["attachment_selection"] == dict(advertised=1, selected=1, exact_listing=True)

        additional = work / "additional.json"
        additional.write_text(json.dumps({"fixture": "unapproved", "note": "x" * 65536}), encoding="utf-8")
        with_extra = work / "with-extra"
        extra = run("artifact-attach", candidate, root, "application/json",
                    "application/json", additional, "unapproved", with_extra)
        extra_target = (with_extra, pin((with_extra / "index.json").read_bytes()), "candidate",
                        origin, REPO, "reviewed", extra)
        extra_plan = json.loads(run("registry-plan-bundle", *extra_target, "--allow-http"))
        extra_receipt = json.loads(run("registry-publish-bundle", *extra_target,
                                       extra_plan["bundlePin"], "--allow-http"))
        assert not extra_receipt["publication"]["tag_written"]

    reconstructed = work / "admitted"
    refused = work / "refused"
    # This origin has been stopped. A malformed or differently scoped lock
    # must be refused locally rather than falling through to connection setup.
    tampered = work / "tampered-lock.json"
    tampered.write_bytes(lock_path.read_bytes() + b"\n")
    run("registry-bundle", origin, REPO, "reviewed", root, root, refused, "--allow-http",
        "--referrer-lock", tampered, "--referrer-lock-pin", lock["pin"], status=5)
    run("registry-bundle", origin, REPO, "reviewed", pin(b"other"), root, refused,
        "--allow-http", *lock_args, status=5)
    assert not refused.exists()

    with launch("consumer") as origin:
        source = (origin, REPO, "reviewed", root, root)
        requirements = ("--allow-http", "--require-artifact", STATEMENT_MEDIA,
                        "--statement-digest", evidence, *lock_args)
        run("registry-admit", *source, refused, *requirements,
            "--statement-predicate", PREDICATE + "-incorrect", status=5)
        assert not refused.exists()
        run("registry-admit", *source, refused, *requirements, "--statement-predicate", PREDICATE,
            "--exact-referrers", status=5)
        assert not refused.exists()
        run("registry-bundle", *source, refused, "--allow-http",
            "--attachment-pins", pin(b"not published"), status=5)
        assert not refused.exists()
        admitted = json.loads(run("registry-admit", *source, reconstructed, *requirements,
                                  "--statement-predicate", PREDICATE))["acquisition"]
        all_referrers = json.loads(run("registry-bundle", *source, work / "all-referrers", "--allow-http"))
        assert admitted["attachment_selection"] == dict(advertised=2, selected=1, exact_listing=False)
        assert admitted["bundle"]["referrers"] == [evidence]
        mirror_source = (origin, mirror, "reviewed", root, root)
        mirror_output = work / "mirror"
        run("registry-admit", *mirror_source, mirror_output, *requirements,
            "--statement-predicate", PREDICATE, "--exact-referrers")
        assert set(all_referrers["bundle"]["referrers"]) == {evidence, extra}
        avoided_bytes = (int(all_referrers["accepted_network_bytes"])
                         - int(admitted["accepted_network_bytes"]))
        assert avoided_bytes >= additional.stat().st_size

    def read_blobs(layout):
        return {entry.name: entry.read_bytes() for entry in (layout / "blobs/sha256").iterdir()}

    expected = read_blobs(candidate)
    recovered = read_blobs(reconstructed)
    assert recovered == expected == read_blobs(mirror_output)
    assert all(pin(value) == "sha256:" + name for name, value in recovered.items())
    print(json.dumps(dict(root=root, statement_manifest=evidence, restored_objects=len(recovered),
                          mounted_blobs=mirrored["mounted_blobs"], mounted_bytes=mirrored["mounted_bytes"],
                          persistent_restart=True, predicate_mismatch_refused=True,
                          admitted_bytes_identical=True, exact_listing_refused_extra=True,
                          missing_pin_refused=True, avoided_network_bytes=avoided_bytes,
                          pinned_lock_roundtrip=True, modified_or_mismatched_lock_refused=True), indent=2))


if __name__ == "__main__":
    main()
