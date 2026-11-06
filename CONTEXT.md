# MoonOCI

**Content Catalog**: An immutable snapshot of verified physical SHA-256 content
and recognized metadata topology. Its store pin includes orphan membership.
It is a content-integrity observation, not a layer/runtime semantic proof.

**Retention Plan**: A caller-selected strong content closure with explicit weak
subject/referrer policy, exact copied metadata and an unsigned review identity.
It creates a new copy and never performs source filesystem deletion.

**Prepared Transfer**: An immutable validated snapshot of a whole-content pin,
size, chunk size and ordered chunk digests. Per-chunk success does not prove the
whole content; final verification remains mandatory.

**Transfer Session**: Caller-owned persisted metadata and verified chunk files,
optionally held through an immutable prepared Native handle. Completion is
rediscovered from actual files after restart, not a trusted completion bitmap.

MoonOCI defines the domain language for creating, inspecting, and validating OCI image layouts without requiring a running container daemon or remote registry.

## Language

**OCI Image Layout**:
A filesystem representation of OCI content consisting of an image-layout marker, an image index, and content-addressed blobs.
_Avoid_: Image folder, Docker directory

**Blob**:
An immutable byte sequence addressed by a cryptographic digest and stored in the layout's content store.
_Avoid_: File object, payload file

**Digest**:
A content identifier composed of an algorithm name and encoded hash value, such as `sha256:<hex>`.
_Avoid_: Checksum ID, file hash

**Descriptor**:
Metadata that identifies referenced content by media type, digest, and byte size, with optional annotations and platform information.
_Avoid_: Blob pointer, file reference

**Image Manifest**:
A document that identifies one image configuration and its ordered filesystem layers for a single platform image.
_Avoid_: Manifest list, image index

**Image Index**:
A document that points to one or more manifests and may distinguish them by platform or annotations.
_Avoid_: Image manifest, manifest list

**Image Configuration**:
Immutable metadata describing the image platform, runtime defaults, history, and the DiffIDs of its filesystem layers.
_Avoid_: Build configuration, project config

**Layer**:
A tar-based filesystem changeset applied in order to construct an image root filesystem.
_Avoid_: Archive, root directory

**DiffID**:
The digest of a layer's uncompressed tar representation, recorded by the image configuration.
_Avoid_: Layer digest

**Layer Digest**:
The digest of the exact layer blob referenced by the image manifest, which may be compressed or uncompressed.
_Avoid_: DiffID

**Layer Interpretation**:
The validated understanding of a layer blob as an uncompressed tar representation, its safe filesystem entries, and its DiffID under the declared media type and resource limits.
_Avoid_: Layer decompression, tar extraction

**Root Filesystem**:
The filesystem state obtained after applying all image layers in manifest order to an empty filesystem.
_Avoid_: Source directory, layer directory

**Root Filesystem Transition**:
The ordered effect of one layer on a prior root filesystem, including additions, replacements, Whiteouts, and Opaque Directories.
_Avoid_: File copy, directory merge

**Descriptor Graph**:
The transitive relationships from an Image Index through Image Manifest Descriptors to Image Configurations and Layers.
_Avoid_: Blob list, manifest tree

**Reproducible Image**:
An image whose content, descriptors, and digests are identical when built repeatedly from identical declared inputs.
_Avoid_: Cached image, stable tag

**Build Specification**:
A declarative document that identifies the target platform, ordered layer sources, image metadata, and requested output.
_Avoid_: Dockerfile, build script

**Layer Source**:
A directory tree consumed as the complete input for one image layer.
_Avoid_: Build context, root filesystem

**Whiteout**:
A special empty layer entry whose name marks a path from lower layers as removed.
_Avoid_: Tombstone, deletion file

**Opaque Directory**:
A directory marked so that children inherited from lower layers are hidden when the layer is applied.
_Avoid_: Deleted directory, empty directory

**Validation Finding**:
A structured error, warning, or informational observation produced while checking an OCI image layout.
_Avoid_: Log line, exception message

**Transfer Envelope**:
A bounded MoonOCI-specific set of missing content and pinned source/target metadata used to reconstruct a complete OCI layout at a receiver.
_Avoid_: Partial OCI image, signed update

**Hydration**:
Verification and assembly of an envelope with existing base content into a fresh complete layout before host materialization.
_Avoid_: In-place patch, extraction

**Release Policy**:
Caller-owned constraints on verified image configuration and content, producing an allow/block decision separately from OCI structural validity.
_Avoid_: Runtime security proof, vulnerability scan

**File Evidence**:
An observation of a final filesystem path bound to its content and contributing layer, with source ownership and link metadata.
_Avoid_: Extracted file, original source file

**Upgrade Approval**:
A host decision accepting observed changed paths or execution fields between two exact pinned manifests.
_Avoid_: Compatibility proof, reusable allowlist
