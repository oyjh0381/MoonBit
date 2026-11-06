# Offline delivery and release decisions

The 0.2.0 source is unpublished. These capabilities extend the library's local
development branch and do not establish quarterly eligibility or remote CI success.

## End-to-end consumer

After building the Native CLI, run:

```text
moon build --target native --release --deny-warn
python scripts/offline_chain.py --binary _build/native/release/build/cmd/moonoci/moonoci.exe
```

The consumer generates amd64/arm64 images sharing one real 64 KiB layer, creates
the same delta twice, verifies byte equality, hydrates a fresh complete layout,
and compares it to the full target with independent CPython JSON/gzip/tar/SHA-256
observation. It refuses the wrong pin without creating the destination, merges
both platforms, selects one and independently checks it. No Linux runtime is
needed for this consumer. Actual Linux execution remains a separate CI chain.

## Transfer format and APIs

`distribution.create_delta(base, target)` selects only reachable target content
missing from the verified base. `encode_delta` writes deterministic tar with
`moonoci-transfer.json`, `index.json`, `oci-layout` and missing digest-addressed
blobs. The metadata uses a MoonOCI-specific media type, versioned v1, with base
and target index digests. It is an application transfer format, not an OCI image
archive and must not be loaded directly into a container runtime.

`decode_delta` refuses nonregular members, unexpected files, missing content,
duplicate descriptors, invalid format metadata and wrong sizes/digests. No
archive member is extracted. `hydrate(base, envelope, expected_target)` requires
a target digest obtained from trusted host release metadata. It checks the base
index, target index, every transported blob and resulting descriptor graph,
including platform/config agreement. Only then does it return a fresh compact
layout. An attacker able to replace both the envelope and trusted pin defeats
the integrity check; authenticating release metadata remains a host concern.

Defaults: 4,096 transferred blobs, 256 MiB per blob, 512 MiB cumulative envelope
content including marker/index, and 16 MiB each for index/descriptor metadata.
Tar overhead is bounded separately. These quotas limit accepted data and decode
work, not total heap usage: the current implementation retains source bytes,
tar members and derived layouts in memory. Native transfer reads check observed
file size before allocation and reject size changes; legacy layout loading is
not streaming. Inputs must remain quiescent while read.

```text
moonoci delta-pack BASE_LAYOUT TARGET_LAYOUT UPDATE.tar
moonoci delta-apply BASE_LAYOUT UPDATE.tar sha256:TRUSTED_INDEX_HASH NEW_LAYOUT
```

Existing destinations are refused. File writing can fail partway; do not treat
a failed command's archive as successfully delivered. Layout materialization
uses the existing staging mechanism only after complete hydration verification.

## Content lifecycle

`reachable_blobs` traverses flat image index branches, deduplicates config/layer/
manifest content and sorts by digest. `storage_inventory` validates physical
records, rejects duplicate physical keys and reports stored/reachable/reclaimable
bytes. `compact` produces a copy with identical root index and only reachable
content; it does not delete source files or modify the input layout. Unreachable
data may be discarded by compaction, while strict inventory refuses malformed
physical records. Nested index/artifact graphs remain unsupported.

The in-memory store now maintains a digest lookup index while retaining record
insertion order. Expected lookup and duplicate detection change from O(B) to
O(1) per lookup, with O(B) additional index memory. Hashing remains O(bytes),
sorting O(B log B), and graph verification/decompression costs remain. No claim
that the complete pipeline is O(1) or universally linear is made.

## Caller-owned release policies

`policy.evaluate` returns `PolicyDecision` and `moonoci.policy.v1` JSON.
Recommended rules require an explicit nonzero numeric UID and Entrypoint/Cmd.
Callers can set platform allowlists, manifest/layer/content quotas, required
nonblank labels and forbidden environment keys. Every image branch is checked;
invalid structure blocks the decision, while invalid policy configuration raises.
`moonoci gate INPUT` exits 0 on allowed, 5 on blocked.

These are declared configuration constraints, not proof of actual process UID,
binary correctness, absence of secrets or runtime isolation. Named users are
conservatively refused by the numeric UID rule because `/etc/passwd` is not
resolved. Hosts may choose a different policy through the public API.
