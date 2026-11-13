# Publish a reviewed release

Use the promotion commands to enforce a rollout policy at the point where a
candidate is published. Each promotion reviews every platform in the baseline
and candidate, so omitting a platform from the policy cannot authorize its
removal or publication. The candidate must advertise a single immutable root.
Aliases of that exact descriptor may coexist.

For a flat multi-platform layout produced by `merge`, give its index a name
with `wrap-release`. The original index bytes become the named nested index.
The wrapper command prints the outer index digest for the rollout policy.

```text
moonoci wrap-release CANDIDATE INDEX_PIN release WRAPPED
moonoci registry-promote-plan BASE WRAPPED POLICY_JSON release https://registry.example team/app patched
moonoci registry-promote BASE WRAPPED POLICY_JSON release https://registry.example team/app patched PROMOTION_PIN
```

Use the policy format in [Multi-platform rollout review](rollout-review.md).
The promotion pin binds the exact policy bytes, both layout index digests,
the candidate's verified physical store, destination origin, repository and
tag, and the ordered publication plan. Recomputing the plan catches changes
to the approval file or destination before a Registry connection. The
successful receipt contains both the promotion pin and the publication receipt.

The command accepts image manifests and indexes. Unknown media, non-image
artifacts and subject-bound objects require a separate publication workflow.
The write transport uses the same create-or-identical behavior as
`registry-publish`. Use a single writer per tag. The host supplies its trusted
approval and, when needed, its Registry credential.

The [rebase consumer](rebase.md) exercises this path against loopback Zot. It
checks that a missing approval and a changed policy are refused before the
approved promotion, then compares ORAS readback with the derived filesystem.

## Promote a release with evidence

Use `registry-promote-bundle-plan` and `registry-promote-bundle` when the
candidate layout contains both the image release and its immediate OCI
attachments. Supply every candidate attachment as a comma-separated digest
list. The plan shows the full publication destination, attachment digests
and artifact types and returns a single `promotionPin`.

```text
moonoci registry-promote-bundle-plan BASE CANDIDATE POLICY_JSON release https://registry.example team/app patched SBOM_PIN,PROOF_PIN
moonoci registry-promote-bundle BASE CANDIDATE POLICY_JSON release https://registry.example team/app patched SBOM_PIN,PROOF_PIN PROMOTION_PIN
```

The candidate index must advertise exactly one image root and the selected
attachments. Each attachment must name the same subject digest, media type
and size. Baseline artifacts are outside the image comparison, so a previously
approved bundle can serve as the next baseline. Unknown media and omitted
image platforms still block the operation. The pin covers the exact policy
bytes and the selected attachments as well as the publication destination.

The target Registry must implement OCI 1.1 referrers. Before publishing the
tag, MoonOCI reads back the attachment manifests and checks that the
Registry advertises their exact metadata. The receipt contains both the
reviewed bundle pin and the publication result. This verifies OCI association
and storage; verification of signatures and evidence documents belongs to the
consumer that interprets those documents.

The attachment consumer in `scripts/registry_attachment_chain.py` checks
both changed-policy and omitted-platform refusals, promotes a two-platform
release to Zot, and independently compares both referrers with ORAS.

## Use a MoonBit-native Registry

[ArtifactDock 0.2.3](https://github.com/Hhsqoo/artifactdock/tree/011f22ae3b2da6651eb223de9502dff1a423a1e5)
provides the server and persistent storage. Build that revision with
\`moon build --target native\` and give its executable to the local consumer.

\`\`\`text
python scripts/artifactdock_chain.py --binary PATH_TO_MOONOCI --artifactdock PATH_TO_ARTIFACTDOCK
\`\`\`

On Windows, the script promoted a two-platform image and one in-toto
Statement, stopped the server, and started a new process with the same store.
The admission command rejected an incorrect predicate type without writing
the destination. With the correct type and manifest pin, it restored nine
objects. Each object matched the original bytes and its SHA-256 path.
The test uses loopback and checks the Statement's subject binding.

## Reuse blobs from another repository

Pass `--mount-from SOURCE_REPOSITORY` when generating and applying a
publication or promotion plan, with or without attachments. The plan pin
binds the named source to the same Registry as the destination. A successful
mount is checked with a destination HEAD for exact digest and size. If the
Registry responds with an upload session, the client completes that session
with the local verified blob. The receipt separates mounted, uploaded and
already-present blobs. The worst-case body budget still covers a full upload.

The ArtifactDock consumer promotes the same release into two repositories,
mounts five blobs totaling 2,784 bytes, then restarts the server and verifies
the same nine object bytes from both repositories.
