# Conformance and compatibility

MoonOCI targets OCI Image Format Specification 1.1.1.

## Implemented

- OCI Image Layout marker version `1.0.0`;
- `index.json` with schema version 2 and reference-name annotation;
- single-platform Image Manifest and Image Configuration;
- SHA-256 content-addressed Blobs;
- uncompressed tar and gzip Layer media types;
- ordered DiffIDs and history;
- Whiteout and Opaque Directory markers;
- Linux platform metadata including architecture, variant, and OS version;
- runtime user, environment, entrypoint, command, working directory, labels, exposed ports, volumes, and stop signal;
- Descriptor graph, exact media type, Digest, size, tar, gzip, and DiffID verification.

## Intentionally unsupported in v0.1

- registry push/pull and Docker daemon integration;
- Dockerfile execution and container runtime behavior;
- signatures, attestations, encryption, and referrers;
- zstd Layers;
- multi-platform assembly in one build invocation;
- sparse files, device nodes, sockets, FIFOs, ACLs, and extended attributes;
- Native import of host symbolic links;
- streaming construction of multi-gigabyte Layers.

## Validation matrix

The unreleased 0.2.0 source adds nested index projection, mixed artifact stores,
bounded read-only Registry pulls and versioned admission rules. Exact
in-toto Statement subject/predicate binding is an optional check separate from
signer trust. The Windows Native consumer compares 517 final inventory entries
from a public Alpine manifest independently acquired by ORAS. See the
[Registry transport profile](registry-transport.md) and
[Statement verification profile](statement-verification.md).

Portable checks and tests run on Wasm, Wasm-GC, JavaScript and Native. Native tests create real Layer Source trees, materialize layouts, reload them, verify them and export deterministic tar archives. The Linux CI workflow also configures Skopeo and Podman consumers. Linux runtime results require an executed runner.

Passing MoonOCI verification means the implemented graph and Layer invariants hold. It does not prove that an arbitrary container runtime can execute the image's application payload.
