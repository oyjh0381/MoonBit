# WebAssembly OCI artifacts

MoonBit projects can package a compiled Wasm module in an OCI Image Layout.
The `wasmartifact` package follows the single-layer CNCF v0 layout. Core
modules use the `wasip1` configuration and components use `wasip2`.
The latter requires a producer-supplied JSON document with `imports` and
`exports` arrays and an optional `target` string.
[CNCF format](https://tag-runtime.cncf.io/wgs/wasm/deliverables/wasm-oci-artifact/)

```text
moon build examples/single-layer --target wasm --release --deny-warn
moon build --target native --deny-warn
moonoci wasm-pack _build/wasm/release/build/examples/single-layer/single-layer.wasm fixture artifact
oras pull --oci-layout artifact:fixture --output restored
moonoci wasm-inspect artifact EXPECTED_INDEX_PIN fixture
moonoci wasm-export artifact EXPECTED_INDEX_PIN fixture verified-module.wasm
```

The CLI prints the manifest digest and creates a new layout. The binary,
configuration and manifest are separate SHA-256 blobs. Repacking identical
inputs produces identical descriptor and index bytes. ORAS restores the original
payload as `module.wasm` for a core module or `component.wasm` for a component.
Use the trusted SHA-256 of `index.json` for the two read commands. They resolve
the exact root reference and check each relevant digest. The export stages the
bytes in the same directory and publishes through a no-replace rename.

Portable callers can call `pack`, `inspect_binary`, or `inspect`. The last
accepts a trusted manifest descriptor and verifies its manifest, config and
payload bytes, checks the advertised platform and verifies the config's
`layerDigests` binding. It accepts external manifests identified by config
media type, including ones that omit the optional `artifactType` field.

The binary reader checks the header and top-level section lengths. Interface
metadata comes from the producer. Full instruction validation, interface
type checking, WASI compatibility and execution belong to the consumer.
This profile accepts a single payload up to 64 MiB and config up to 1 MiB.

The Windows/Linux workflow compiles the MoonBit example and checks the resulting
layout with CPython and ORAS. On Windows, ORAS 1.3.6 recovered all 227,871 bytes
of the compiled fixture with the same SHA-256 digest as the compiler output.
The consumer also constructs a separate layout with ORAS, inspects its Wasm
configuration, then verifies that the extracted binary is byte-identical.
