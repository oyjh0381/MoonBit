# OCI artifacts, referrers and release requirements

The local 0.2.0 source includes an `artifacts` package for the OCI 1.1 image
manifest's artifact usage, plus a Native consumer that interoperates with ORAS.
It does not implement a registry server, HTTP push/pull, document-schema
validation, signing or trust-root verification.

## Artifact format and content checking

`ArtifactManifest` retains `artifactType`, config, ordered payload descriptors,
optional subject and annotations. Encoding sorts annotation keys and preserves
payload order. `build` creates a standalone layout; `attach` returns a copy of
an existing layout with a subject-bound artifact. Both use the OCI empty config
(`{}`) and metadata-only artifacts get one empty-descriptor layer for portability.
The type/subtype validator accepts the bare-name profile, without wildcard or
parameter syntax. Unknown valid names remain usable payload/config types.

`inspect` verifies manifest/config/payload byte sizes and SHA-256, under limits.
Defaults: 1,024 payloads, 64 MiB each, 256 MiB total artifact bytes, 4 MiB manifest
and 1 MiB config. Custom config media are treated as bytes, not parsed as image
configuration. Subject is a weak reference: its graph may be elsewhere. An
explicit `require_subject=true` refuses unavailable local subject content.
Locally available subject bytes are checked, but this does not validate all of
that subject's execution semantics or authenticate its origin.

`verify_store` combines the existing image verification profile with artifact
payload verification. It reports unrecognized media as unverified rather than
calling it corrupt. It defaults to a 512 MiB aggregate logical artifact-payload
work budget, reserving bytes before inspection so failed attempts cannot reset
the budget. Unreferenced physical blobs are outside this advertised-content check.
`complete` describes media coverage, and `valid` also requires no verification
findings. These are independent of document meaning, trust and container startup.

## Binding multi-platform releases

`resolve_subject` resolves advertised image/artifact/index descriptors or the
layout's anonymous root index. When attaching to a root index, the exact
pre-attachment bytes are retained as a Blob and advertised as an index descriptor.
The attachment changes the collection root, while its subject digest stays bound
to the original release index. Advertising that preserved descriptor is required
by the tested ORAS client's digest media-type resolution.

Attach multiple documents to the same stable release subject rather than
repeatedly treating each new collection root as a new release. The latter creates
additional retained index ancestry, still subject to graph depth/visit limits.

## Discovery and advertisements

`referrers` scans advertised nested metadata and deduplicates by digest. It can
filter exact artifact types. The JSON index includes artifact type and annotations
from each referring manifest/index, matching the OCI referrers response shape.
Image manifests without an explicit type use their config media type; indexes
without a type omit it. Unknown media leave discovery incomplete. This is offline
discovery, not an implementation of HTTP pagination or registry completeness.

`decode_referrer_page` preserves the `artifactType` extension omitted by the
generic descriptor model and rejects duplicate advertisements. `verify_referrer_page`
checks a page's advertised size/type/annotations/subject against content-addressed
metadata. A valid page does not prove there are no other pages, and metadata
checking does not verify the payloads or a signature.

`export_artifact` copies only an artifact's manifest/config/payload closure and
retains its subject as a weak external reference. `payload_bytes` retrieves by
numeric position. Neither API chooses a host path from untrusted title annotations.

## Caller-owned release requirements

`policy.evaluate_artifact_requirements` requires configured types and min/max
counts for a specified subject. Counted attachments must pass content checks and
have their subject locally available. Invalid content, incomplete discovery and
missing requirements block the decision. Limits are checked even for an empty
requirement set; aggregate payload work is bounded and charged before inspection.
This proves presence and content identity only. A JSON document named SPDX or
in-toto has not thereby been schema-validated or authenticated.

```text
moonoci artifact-attach INPUT SUBJECT TYPE PAYLOAD_MEDIA FILE REF OUTPUT
moonoci artifact-inspect INPUT ARTIFACT_DIGEST
moonoci referrers INPUT SUBJECT [ARTIFACT_TYPE]
moonoci verify-store INPUT
moonoci artifact-gate INPUT SUBJECT REQUIRED_TYPE [REQUIRED_TYPE...]
moonoci artifact-export INPUT ARTIFACT_DIGEST OUTPUT
moonoci artifact-payload INPUT ARTIFACT_DIGEST INDEX OUTPUT_FILE
```

Native payload inputs are size-checked before allocation, capped at 64 MiB, and
size changes are refused. Input trees/files must remain trusted and quiescent;
equal-size concurrent rewrites are not detected. The loader remains in-memory.
Existing output layouts and payload files are refused. `verify-store` and gates
exit 5 when blocked. Incomplete discovery prints the OCI index plus a warning
and exits 4, so automation cannot silently treat it as a complete listing.

## Reproducible independent consumption

```text
moon build --target native --release --deny-warn
python scripts/setup_oras.py
python scripts/artifact_chain.py --binary _build/native/release/build/cmd/moonoci/moonoci.exe --oras _build/tools/oras-1.3.6/windows_amd64/oras.exe
```

Use the corresponding `linux_amd64/oras` path on Linux. The bootstrap uses the
official 1.3.6 archives with pinned SHA-256, extracts only the expected binary
member under ignored `_build/tools`, and leaves system PATH unchanged. An existing
archive can be supplied with `--archive`, still requiring the same checksum.

The consumer attaches two illustrative documents, checks raw content hashes and
subject relationships with Python, exercises required-type gates, exports payloads
without overwriting files, and refuses corrupted content. ORAS independently
fetches both manifests and payloads, discovers/refines the same referrers, and
discovers a release attachment bound to a multi-platform index. It records the
actual ORAS version. Without `--oras`, external checks are explicitly recorded as
not run. Example documents do not constitute full SPDX/in-toto schema fixtures.

The Windows ORAS 1.3.6 path was actually executed locally. The added Linux/Windows
CI jobs remain pending until an authorized push; Linux container startup is a
separate pending runtime consumer. Generated reports, downloaded binaries and
administrative materials stay excluded from Git/package artifacts.

References: [OCI artifact manifest guidance](https://github.com/opencontainers/image-spec/blob/v1.1.1/manifest.md),
[OCI referrers discovery](https://github.com/opencontainers/distribution-spec/blob/v1.1.1/spec.md#listing-referrers),
[ORAS manifest fetch](https://oras.land/docs/commands/oras_manifest_fetch/).
