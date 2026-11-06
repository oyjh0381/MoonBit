///|
test "filesystem query refuses implicit selection from multi-platform layouts" {
  let request = @builder.default_single_layer_request([
    @archive.TarEntry::file("amd-only", b"amd"),
  ])
  let a = @builder.build_single_layer(request)
  let b = @builder.build_single_layer({
    ..request,
    platform: { ..request.platform, architecture: "arm64", },
    entries: [@archive.TarEntry::file("arm-only", b"arm")],
  })
  for blob in b.layout.blob_records() {
    ignore(a.layout.put_blob(blob.descriptor().media_type, blob.data()))
  }
  let index = @codec.decode_index(a.layout.index())
  a.layout.set_index(
    @codec.encode_index({
      ..index,
      manifests: [a.report.manifest, b.report.manifest],
    }),
  )
  let ambiguous = try {
    ignore(@builder.rootfs_from_layout(a.layout))
    false
  } catch {
    _ => true
  }
  assert_true(ambiguous)
  assert_eq(
    @builder.rootfs_from_manifest(a.layout, a.report.manifest).map(e => e.path),
    ["amd-only"],
  )
  assert_eq(
    @builder.rootfs_from_manifest(a.layout, b.report.manifest).map(e => e.path),
    ["arm-only"],
  )
}

///|
test "filesystem selection rejects descriptors outside the index" {
  let a = @builder.build_single_layer(
    @builder.default_single_layer_request([@archive.TarEntry::file("a", b"a")]),
  )
  let b = @builder.build_single_layer(
    @builder.default_single_layer_request([@archive.TarEntry::file("b", b"b")]),
  )
  for blob in b.layout.blob_records() {
    ignore(a.layout.put_blob(blob.descriptor().media_type, blob.data()))
  }
  let rejected = try {
    ignore(@builder.rootfs_from_manifest(a.layout, b.report.manifest))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
