# Nested image indexes and image projection

The `graph` package consumes nested OCI indexes without changing the existing
flat-image verifier profile. It supports an explicit derived image view usable
with the existing distribution, policy, filesystem and transfer packages.

## Bounded metadata inspection

`walk_indexes` validates the layout marker and supported index/manifest/config
metadata, retaining leaf index paths, ancestor index digests and config platforms.
Defaults are 16 descriptor levels, 4,096 visits and 128 MiB of distinct metadata
bytes, including the root index. JSON decoding also retains its existing 16 MiB
document bound. Layer payloads are not loaded/verified by this metadata walk.
Repeated references count toward visit limits; verified metadata bytes are
memoized by digest, with inconsistent descriptor sizes refused. Recursion-stack
checks guard cyclic references, and excessive depth or visits fail explicitly.

Unknown media are reported as skipped, without fetching their possibly absent
content. A known manifest with a non-image config is also reported as skipped.
The walk's `complete` means all visited descriptors were recognized as supported
image metadata, not that every layer was verified or every runtime requirement
is satisfied. This distinction follows the OCI index requirement to tolerate
[unrecognized media types](https://github.com/opencontainers/image-spec/blob/v1.1.1/image-index.md).

## Derived image views

`flatten_images` preserves source traversal order and leaf annotations, obtains
missing platform declarations from image config, builds a flat image index and
verifies/compacts its full image content. It refuses skipped entries by default.
`allow_skipped=true` explicitly requests only the recognized image projection.
`select_image` returns one exact OS/architecture/variant/OS-version image; repeated
aliases of identical image content are accepted, while distinct matches fail.

These operations create a new root index with a new digest; they do not preserve
the original nested topology, parent reference annotations, artifact associations
or unmodeled extension fields. Ancestor platform constraints are checked against
the modeled config platform. Selection does not resolve OS features, host version
compatibility or ISA compatibility. It is not a general Windows image/runtime
compatibility engine or artifact graph implementation. Preserve the original
source and pins when these additional associations matter.

The selected/projected image graph is fully checked using the existing tar/gzip/
DiffID profile. Skipped unrelated content is not asserted valid. Selection still
checks known metadata across the tree, and may fail on malformed known metadata
outside the selected payload branch.

## Trusted pins and derivation records

`walk_pinned` checks an externally trusted root index digest before traversing
metadata. `project_pinned` also returns an unsigned `ProjectionReceipt` with
source index digest, projected index digest, image manifest digests and skipped
count. The receipt is computed from actual source/output bytes; authenticating
the root pin and storing/signing a receipt remain host responsibilities.

```text
moonoci tree INPUT
moonoci flatten INPUT OUTPUT
moonoci flatten INPUT OUTPUT --images-only
moonoci tree-select INPUT OUTPUT linux arm64
moonoci flatten-pinned INPUT sha256:TRUSTED_ROOT_HASH OUTPUT
```

The Native loader currently reads the layout before library traversal, so graph
metadata quotas are not a streaming filesystem memory cap. All output commands
refuse an existing destination. `tree` is inspection output, not a layer-verifier
verdict. `flatten-pinned` emits its receipt only after output materialization.

## Independent consumption test

```text
moon build --target native --release --deny-warn
python scripts/nested_chain.py --binary _build/native/release/build/cmd/moonoci/moonoci.exe
```

CPython independently builds two nested index levels and digest-addressed index
blobs over actual MoonOCI images. MoonOCI traverses these externally generated
documents and projects/selects images; the independent tar/gzip/SHA-256 observer
compares them to the original flat images. Wrong descriptor sizes, excessive
depth, silent omission of unknown media and stale root pins are refused. Explicit
image-only projection and source/output receipt hashes are verified separately.
Generated reports stay in `_build/nested-*/`, excluded from repository/package.

Metadata traversal is bounded by visits and bytes, and repeated metadata hashes
are cached. Projection additionally incurs existing complete image validation,
decompression and compaction costs. There is no universal linear-time or bounded
process-heap claim.
