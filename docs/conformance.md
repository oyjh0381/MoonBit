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

Portable checks run on Wasm, Wasm-GC, JavaScript, and Native compilation targets. Executable tests run on Wasm-GC and Native; Native tests create real Layer Source trees, materialize layouts, reload them, verify them, and export deterministic tar archives. CI additionally builds a sample layout and uses Skopeo on Linux when available to provide independent OCI parsing.

Passing MoonOCI verification means the implemented graph and Layer invariants hold. It does not prove that an arbitrary container runtime can execute the image's application payload.
