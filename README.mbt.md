# Executable MoonOCI overview

This module README documents the minimal portable build path. The same request is used in `examples/single-layer`.

The local 0.2.0 source additionally provides `distribution` for multi-platform
composition, compact storage and pinned offline transfer/hydration, and `policy`
for caller-owned release decisions. It is unreleased; the following command
installs the earlier published version. Reproducible consumers are documented
in `docs/offline-delivery.md` and `docs/runtime-validation.md`.

Install the published module with:

```text
moon add oyjh0381/moonoci@0.1.4
```

```mbt check
test "README single-layer build" {
  let request = @builder.default_single_layer_request([
    @archive.TarEntry::file("hello.txt", b"hello MoonOCI\n"),
  ])
  let image = @builder.build_single_layer(request)
  assert_true(@builder.verify_memory(image.layout).is_valid())
  assert_eq(image.report.layers.length(), 1)
}
```

MoonOCI deliberately requires explicit creation time. If `created` is absent, the corresponding OCI field is omitted instead of reading the system clock.
