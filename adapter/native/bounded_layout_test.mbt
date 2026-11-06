///|
async test "bounded layout loader preflights count metadata and aggregate quotas" {
  let root = "_build/native-bounded-layout"
  if @fs.exists(root) {
    @fs.rmdir(root, recursive=true)
  }
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"image"),
    ]),
  )
  @native.write_layout(root, image.layout)
  let loaded = @native.load_bounded_layout(root)
  assert_true(@builder.verify_memory(loaded).is_valid())
  assert_eq(loaded.blob_count(), image.layout.blob_count())
  for
    limits in [
      { ..@native.LayoutLoadLimits::default(), max_blobs: 1, },
      { ..@native.LayoutLoadLimits::default(), max_blob_bytes: 1, },
      { ..@native.LayoutLoadLimits::default(), max_total_bytes: 1L, },
      { ..@native.LayoutLoadLimits::default(), max_index_bytes: 1, },
    ] {
    let rejected = try {
      ignore(@native.load_bounded_layout(root, limits~))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  @fs.mkdir(root + "/blobs/sha512")
  let rejected = try {
    ignore(@native.load_bounded_layout(root))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  @fs.rmdir(root, recursive=true)
}
