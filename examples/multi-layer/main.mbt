///|
fn main {
  run() catch {
    error => abort("multi-layer example failed: \{error}")
  }
}

///|
fn run() -> Unit raise {
  let request : @build.ImageBuildRequest = {
    layers: [
      {
        entries: [
          @archive.TarEntry::directory("app"),
          @archive.TarEntry::file("app/old.txt", b"old\n"),
          @archive.TarEntry::directory("cache"),
          @archive.TarEntry::file("cache/old.bin", b"old cache"),
        ],
        remove: [],
        opaque_dirs: [],
        compression: @model.Compression::Uncompressed,
      },
      {
        entries: [
          @archive.TarEntry::file("app/new.txt", b"new\n"),
          @archive.TarEntry::file("cache/current.bin", b"new cache"),
        ],
        remove: ["app/old.txt"],
        opaque_dirs: ["cache"],
        compression: @model.Compression::Gzip,
      },
    ],
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: Some("MoonOCI example"),
    reference: "multi-layer",
    annotations: [],
  }
  let image = @build.build_image(request)
  for entry in image.rootfs {
    println("\{entry.kind}\t\{entry.path}\tlayer=\{entry.layer_index}")
  }
}
