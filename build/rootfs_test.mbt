///|
test "Root Filesystem can be reconstructed from layout Blobs" {
  let request : ImageBuildRequest = {
    layers: [
      {
        entries: [
          @archive.TarEntry::directory("dir"),
          @archive.TarEntry::file("dir/old", b"old"),
          @archive.TarEntry::file("gone", b"gone"),
        ],
        remove: [],
        opaque_dirs: [],
        compression: @model.Compression::Uncompressed,
      },
      {
        entries: [@archive.TarEntry::file("dir/new", b"new")],
        remove: ["gone"],
        opaque_dirs: ["dir"],
        compression: @model.Compression::Gzip,
      },
    ],
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "rootfs",
    annotations: [],
  }
  let result = build_image(request)
  assert_eq(rootfs_from_layout(result.layout), result.rootfs)
}
