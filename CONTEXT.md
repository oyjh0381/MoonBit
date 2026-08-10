# MoonOCI

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

**Root Filesystem**:
The filesystem state obtained after applying all image layers in manifest order to an empty filesystem.
_Avoid_: Source directory, layer directory

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
