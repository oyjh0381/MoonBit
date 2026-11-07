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

## Versioned policy files

`moonoci gate-store INPUT POLICY_JSON` reads a caller-owned file bounded to
64 KiB and applies `decode_release_policy`. Example:

```json
{
  "schemaVersion": 1,
  "maxManifests": 16,
  "maxLayersPerImage": 128,
  "maxReachableBytes": "536870912",
  "allowedPlatforms": [{"os": "linux", "architecture": "amd64"}],
  "requireNumericNonroot": true,
  "requireCommand": true,
  "requiredLabels": ["org.opencontainers.image.source"],
  "forbiddenEnvNames": ["BUILD_TOKEN"]
}
```

Missing fields use recommended defaults. `allowedPlatforms` omitted means
unrestricted; an explicit empty array allows no platforms. Optional platform
fields are `variant` and `osVersion`, matched exactly. Byte budgets use decimal
strings to preserve Int64 values beyond JavaScript's safe integer range. Counts
use unsigned decimal integer tokens; fractions and exponent notation are refused.
Unknown fields, duplicate JSON names, duplicate list entries, wrong types,
unsupported versions and overflowing integers are errors rather than silently
ignored rules. Metadata name lists are limited to 64 and platforms to 256.

## Registry admission integration

Add `--release-policy POLICY_JSON` to `registry-admit` to compose the required
attachment decision with all-platform mixed release policy before publication.
The library option is `admit_registry_release(..., release_policy=policy)`.
Either decision can block; JSON reports keep artifact and release results
separate. An absent option means attachment-only admission and is explicitly
represented by a null `release_decision`. Invalid policy documents are refused
before HTTP. Caller-owned policy arrays are copied before asynchronous work.

The Registry fixture exercises recommended-policy rejection, an explicit custom
policy pass, and a platform allowlist rejecting a secondary platform even when
required attachments pass. Every rejected candidate leaves no output directory.
