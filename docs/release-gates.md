# Mixed release policy

`policy.evaluate_mixed` first validates the whole supported image/artifact store,
then projects every distinct image branch for caller-owned runtime/configuration
policy. Valid attachments are retained in the original source. Unknown metadata,
invalid payloads and artifact-only stores cannot silently pass. The JSON decision
binds the observed root index digest and reports store and image-policy outcomes
separately. This checks declared metadata, not runtime isolation or vulnerability
status, and does not inspect unreferenced physical orphans.

```text
moonoci gate-store offline-release
python scripts/policy_chain.py --binary <moonoci>
```

The recommended policy requires a nonzero numeric UID and Entrypoint or Cmd,
with 16 image manifests, 128 layers per image and 512 MiB reachable image content.
Library callers can configure platform allowlists, required labels and forbidden
environment variable names; environment values are not emitted by findings.
Malformed policy configuration raises before source processing. Policy rejection
is distinct from structurally invalid images and produces a blocked decision.

The consumer builds two platforms plus an attachment, checks acceptance, replaces
the second platform with a root-user image and checks rejection, then checks that
an artifact-only export cannot masquerade as a runnable image release. This is
executable on Windows without Docker/Linux and is configured in Linux CI too;
it does not claim that any container was run.
