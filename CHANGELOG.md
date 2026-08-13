# Changelog

All notable changes to MoonOCI are documented here. The format follows Keep a Changelog and versions follow Semantic Versioning.

## [Unreleased]

## [0.1.4] - 2026-08-13

### Added

- Accumulate independent Descriptor graph findings with precise object paths
  and successful-object counts.
- Record the strict unsupported Layer media-type decision in ADR-0006.

### Changed

- Unify declared changesets and archived Whiteouts behind one Root Filesystem
  Transition implementation.
- Centralize media type, bounded decompression, safe tar parsing, and DiffID
  calculation in a Layer Interpretation module.

## [0.1.3] - 2026-08-13

### Fixed

- Reject duplicate runtime object-set members before encoding OCI JSON.
- Bound PAX record-length parsing and reject GNU sparse PAX metadata.
- Enforce Index, Manifest, Configuration, and Layer media types during verification.
- Reject Windows drive-qualified symbolic-link targets on every platform.

### Changed

- Document direct mooncakes.io installation and source-based CLI invocation.
- Add CI checks for generated documentation and committed package interfaces.

## [0.1.2] - 2026-08-11

### Fixed

- Replace the legacy gzip dependency with `hustcer/fzip`, avoiding its stale
  transitive `moonbitlang/x@0.4.40` dependency while preserving deterministic
  gzip headers, checksum validation, and decompression resource limits.

## [0.1.1] - 2026-08-11

### Fixed

- Rename the public `build` source package to `builder` so documentation
  services do not mistake it for generated build output.
- Keep the CLI version output aligned with the published module version.

## [0.1.0] - 2026-08-10

### Added

- Deterministic OCI Image Layout build and verification core.
- USTAR/PAX writer and USTAR/PAX/GNU safety-focused reader.
- Uncompressed and gzip Layers with DiffID validation.
- Strict Build Specification v1 and Native filesystem adapter.
- Multi-layer Whiteout/Opaque Directory Root Filesystem semantics.
- `build`, `inspect`, `list`, `verify`, `archive`, and `version` CLI commands.
- Portable, property-based, corruption, reproducibility, and Native integration tests.
- Semantic OCI Layout marker parsing, immutable in-memory Blob storage, strict
  symlink/Whiteout validation, and `SOURCE_DATE_EPOCH` support.

Initial competition release candidate.
