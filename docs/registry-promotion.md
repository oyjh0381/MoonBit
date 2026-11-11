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
