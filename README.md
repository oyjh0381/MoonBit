# MoonOCI

MoonOCI is an original MoonBit library and command-line tool for building, inspecting, and validating deterministic [OCI Image Layout](https://github.com/opencontainers/image-spec/blob/v1.1.1/image-layout.md) directories without a container daemon or registry.

It provides a portable core for Wasm, Wasm-GC, JavaScript, and Native targets, plus a Native filesystem adapter and the `moonoci` CLI. Identical declared inputs produce byte-identical tar layers, OCI JSON documents, descriptors, and content-addressed Blobs.

## Features

- deterministic USTAR/PAX writer and safety-focused USTAR/PAX/GNU reader;
- SHA-256 Digest and content-addressed in-memory OCI Image Layout;
- uncompressed and deterministic gzip Layers with correct compressed Layer Digest and uncompressed DiffID handling;
- ordered multi-layer builds with Whiteout and Opaque Directory semantics;
- strict, versioned JSON Build Specification;
- descriptor-graph, size, Digest, tar, gzip, and DiffID verification;
- Root Filesystem reconstruction;
- Native `build`, `inspect`, `list`, `verify`, `archive`, and `version` commands;
- generated-case, corruption, Native filesystem, and reproducibility tests.

## Scope

MoonOCI v0.1 builds one platform image per invocation and writes OCI Image Spec 1.1.1 layouts. It does not parse Dockerfiles, run containers, contact registries, sign images, or encode zstd Layers. The portable archive API represents symbolic links, but the v0.1 Native Layer Source adapter rejects host symlinks because its filesystem dependency does not expose a portable read-link operation.

## Requirements

- MoonBit toolchain 0.1.20260803 or newer;
- for Native builds on Windows: Visual Studio 2022 Build Tools with the C++ workload and Windows SDK;
- for Native builds on Linux: a C compiler and archiver.

Install dependencies:

```text
moon update
```

Check the portable packages and run the portable suite:

```text
moon check --target all
moon test --target wasm-gc
```

On Windows, run Native commands in a Developer PowerShell/Command Prompt:

```text
moon test --target native
moon build --target native
```

## Library example

```moonbit
let request = @builder.default_single_layer_request([
  @archive.TarEntry::directory("app"),
  @archive.TarEntry::file("app/message.txt", b"hello\n"),
])
let image = @builder.build_single_layer(request)
assert_true(@builder.verify_memory(image.layout).is_valid())
```

Run the examples:

```text
moon run examples/single-layer --target wasm-gc
moon run examples/multi-layer --target wasm-gc
moon run examples/reproducible --target wasm-gc
```

## Build Specification and CLI

Create `moonoci.json`:

```json
{
  "schemaVersion": 1,
  "ref": "demo",
  "platform": { "os": "linux", "architecture": "amd64" },
  "layers": [
    { "source": "rootfs", "compression": "gzip" }
  ],
  "config": {
    "entrypoint": ["/app/server"],
    "workingDir": "/app"
  },
  "output": { "layout": "dist/demo" }
}
```

Then use the Native executable:

```text
moonoci build moonoci.json
moonoci inspect dist/demo
moonoci list dist/demo
moonoci verify dist/demo
moonoci archive dist/demo dist/demo.tar
moonoci version
```

The builder refuses to overwrite an existing destination. Errors include stable `MOONOCI_*` codes and documented exit classes: arguments/specification `2`, I/O `3`, unsupported or malformed content `4`, verification/security failures `5`, and unexpected internal failure `70`.

## Documentation

- [中文说明](README_zh_CN.md)
- [Build Specification](docs/build-spec.md)
- [Architecture](docs/architecture.md)
- [Security model](docs/security.md)
- [Conformance](docs/conformance.md)
- [Domain language](CONTEXT.md)

## License

Apache License 2.0. Dependency notices are recorded in `THIRD_PARTY_NOTICES.md`.
