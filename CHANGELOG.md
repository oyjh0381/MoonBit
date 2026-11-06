# Changelog

All notable changes to MoonOCI are documented here. The format follows Keep a Changelog and versions follow Semantic Versioning.

## [Unreleased]

- Add bounded pinned chunk plans, versioned metadata and mandatory whole-content verification.
- Stream file planning/export and persist restartable sessions without trusting completion counters.
- Recover verified pending chunks/complete partial outputs, retaining corrupt evidence without replacement.
- Reuse prepared Native host sessions and schedule missing work under simultaneous byte/count budgets.
- Execute a Windows delta-resume consumer and independently checked producer workloads; configure Linux/Windows CI.

- Add OCI 1.1 artifact manifests, bounded payload inspection and nonmutating subject attachments.
- Discover/filter offline referrers and parse/verify registry-style advertisement pages.
- Verify mixed image/artifact stores and enforce caller-required attachments under work budgets.
- Preserve and advertise multi-platform index subjects for ORAS digest resolution.
- Add bounded Native artifact commands and an actually executed Windows ORAS 1.3.6 consumer.

- Traverse nested image indexes with metadata/depth/visit limits and explicit unknown-media observations.
- Project/select complete image layouts and bind root pins to unsigned derivation receipts.
- Add a Python-authored nested-index interoperability consumer with pin/corruption/depth rejection cases.

- Trace final file payloads, ownership, timestamps and links to contributing layers.
- Compare file content and execution configuration; bind explicit upgrade review to both exact versions.
- Expose read-only inventory/diff/config-diff/upgrade-check commands and an independently observed consumer.
- Reject implicit first-manifest filesystem selection in multi-image layouts.
- Correct the development observer's root opacity and directory-replacement handling and independently check provenance.

- Develop 0.2.0 against MoonBit 0.10.16 with supported dependencies and explicit exports.
- Compose/select flat multi-platform image distributions with platform/config checks.
- Plan and serialize missing-content updates, verify externally pinned envelopes and hydrate complete standalone layouts.
- Account reachable/stored/reclaimable bytes and compact copies without mutating source layouts.
- Index content-addressed lookups while preserving physical record order and duplicate-input diagnostics.
- Evaluate caller-owned release policies for every image branch, with structured decisions and CLI gating.
- Add a cross-platform independently observed offline consumer and a Linux self-hosted runtime CI chain; remote runtime results are pending.

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
