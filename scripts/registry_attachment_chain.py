"""Publish pinned release attachments to Zot and rediscover them with ORAS."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from registry_publish_chain import ROOT, REPO, build_layout, fixture, pin, run_zot, serve


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--oras", type=Path, required=True)
    parser.add_argument("--zot", type=Path, required=True)
    args = parser.parse_args()
    binary, oras, zot = (path.resolve(strict=True) for path in (args.binary, args.oras, args.zot))
    work = Path(tempfile.mkdtemp(prefix="publish-attachments-", dir=ROOT / "_build"))
    environment = os.environ.copy()
    environment.pop("MOONOCI_REGISTRY_PUSH_TOKEN", None)
    auth = work / "empty-auth.json"
    auth.write_bytes(b"{}")

    def run(*arguments, status=0, executable=binary):
        result = subprocess.run([str(executable), *map(str, arguments)], cwd=work,
                                env=environment, capture_output=True, text=True,
                                encoding="utf-8", timeout=90)
        if result.returncode != status:
            raise RuntimeError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout.strip()

    baseline, baseline_pin, root = build_layout(run, work)
    layout = baseline
    expected = {}
    for label, media in [("sbom", "application/spdx+json"), ("proof", "application/in-toto+json")]:
        payload = work / (label + ".json")
        payload.write_text(json.dumps({"fixture": label, "subjectDigest": root}), encoding="utf-8")
        output = work / ("with-" + label)
        digest = run("artifact-attach", layout, root, media, "application/json", payload, label, output)
        expected[digest] = media
        layout = output
    source_pin = pin((layout / "index.json").read_bytes())
    selected = ",".join(expected)

    policy = work / "promotion.json"
    required = [dict(os="linux", architecture=arch) for arch in ("amd64", "arm64")]
    policy_document = dict(schemaVersion=1, baselineIndex=baseline_pin,
                           candidateIndex=source_pin, requiredPlatforms=required)
    policy.write_text(json.dumps(policy_document), encoding="utf-8")

    def promotion_target(origin):
        return (baseline, layout, policy, "candidate", origin, REPO + "-promotion", "reviewed", selected)

    def target(origin):
        return (layout, source_pin, "candidate", origin, REPO, "annotated", selected)

    # The wire fixture supports writes but does not implement OCI referrers.
    # A failed attachment acknowledgement must leave the final tag absent.
    handler, state = fixture()
    state["failed"] = True
    with serve(handler) as origin:
        inputs = target(origin)
        plan = json.loads(run("registry-plan-bundle", *inputs, "--allow-http"))
        run("registry-publish-bundle", *inputs, pin(b"wrong plan"), "--allow-http", status=5)
        assert not state["requests"]
        promotion_inputs = promotion_target(origin)
        review = json.loads(run("registry-promote-bundle-plan", *promotion_inputs, "--allow-http"))
        original_policy = policy.read_bytes()
        policy.write_bytes(original_policy + b"\n")
        run("registry-promote-bundle", *promotion_inputs, review["promotionPin"], "--allow-http", status=5)
        policy.write_text(json.dumps(dict(policy_document, requiredPlatforms=required[:1])),
                          encoding="utf-8")
        run("registry-promote-bundle-plan", *promotion_inputs, "--allow-http", status=5)
        policy.write_bytes(original_policy)
        assert not state["requests"]
        run("registry-publish-bundle", *inputs, plan["bundlePin"], "--allow-http", status=4)
        assert not state["tags"] and root in state["manifests"]

    with run_zot(zot, work) as origin:
        inputs = target(origin)
        plan = json.loads(run("registry-plan-bundle", *inputs, "--allow-http"))
        assert plan["root"] == root
        assert {item["digest"]: item["artifactType"] for item in plan["attachments"]} == expected
        result = json.loads(run("registry-publish-bundle", *inputs, plan["bundlePin"], "--allow-http"))
        assert result["verifiedAttachments"] == 2 and result["listingPages"] >= 1
        assert result["publication"]["root"] == root and result["publication"]["tag_written"]
        retry = json.loads(run("registry-publish-bundle", *inputs, plan["bundlePin"], "--allow-http"))
        assert retry["publication"]["uploaded_bytes"] == "0" and not retry["publication"]["tag_written"]
        destination = origin.removeprefix("http://") + "/" + REPO + ":annotated"
        discoveries = json.loads(run("discover", "--plain-http", "--registry-config", auth,
            "--format", "json", "--depth", "1", destination, executable=oras))
        assert {item["digest"]: item["artifactType"] for item in discoveries["referrers"]} == expected

        promotion_inputs = promotion_target(origin)
        review = json.loads(run("registry-promote-bundle-plan", *promotion_inputs, "--allow-http"))
        assert {item["digest"]: item["artifactType"] for item in review["bundle"]["attachments"]} == expected
        receipt = json.loads(run("registry-promote-bundle", *promotion_inputs, review["promotionPin"],
                                 "--allow-http"))
        assert receipt["promotionPin"] == review["promotionPin"]
        assert receipt["bundle"]["bundlePin"] == review["bundlePin"]
        assert receipt["bundle"]["verifiedAttachments"] == len(expected)
        assert receipt["publication"]["root"] == root and receipt["publication"]["tag_written"]
        destination = origin.removeprefix("http://") + "/" + REPO + "-promotion:reviewed"
        discoveries = json.loads(run("discover", "--plain-http", "--registry-config", auth,
            "--format", "json", "--depth", "1", destination, executable=oras))
        assert {item["digest"]: item["artifactType"] for item in discoveries["referrers"]} == expected

    print(json.dumps(dict(root=root, approved_referrers=len(expected),
        listing_pages=result["listingPages"], oras_verified=True,
        retry_uploaded_bytes=0, unapproved_plan_sent_no_requests=True,
        combined_promotion_oras_verified=True, omitted_platform_refused=True,
        changed_policy_sent_no_requests=True,
        registry_without_referrers_left_tag_unset=True), indent=2))


if __name__ == "__main__":
    main()
