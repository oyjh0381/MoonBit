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
