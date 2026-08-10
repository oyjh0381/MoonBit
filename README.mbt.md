# Executable MoonOCI overview

This module README documents the minimal portable build path. The same request is used in `examples/single-layer`.

```mbt check
test "README single-layer build" {
  let request = @build.default_single_layer_request([
    @archive.TarEntry::file("hello.txt", b"hello MoonOCI\n"),
  ])
  let image = @build.build_single_layer(request)
  assert_true(@build.verify_memory(image.layout).is_valid())
  assert_eq(image.report.layers.length(), 1)
}
```

MoonOCI deliberately requires explicit creation time. If `created` is absent, the corresponding OCI field is omitted instead of reading the system clock.
