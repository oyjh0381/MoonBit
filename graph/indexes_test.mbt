///|
fn image(arch : String) -> @builder.BuildResult raise @model.MoonOciError {
  let request = @builder.default_single_layer_request([
    @archive.TarEntry::file("data", b"hello"),
  ])
  @builder.build_single_layer({
    ..request,
    platform: { ..request.platform, architecture: arch, },
  })
}

///|
fn nest(
  source : @layout.MemoryLayout,
) -> @layout.MemoryLayout raise @model.MoonOciError {
  let descriptor = source.put_blob(@model.media_type_index, source.index())
  source.set_index(
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests: [descriptor],
      annotations: [],
    }),
  )
  source
}

///|
test "nested metadata traversal and flattening preserve verified image content" {
  let a = image("amd64")
  let b = image("arm64")
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
  let tree = nest(nest(a.layout))
  let walk = @graph.walk_indexes(tree)
  assert_true(walk.complete)
  assert_eq(walk.images.length(), 2)
  assert_eq(walk.images[0].index_path, [0, 0, 0])
  assert_eq(walk.images[1].ancestor_indexes.length(), 2)
  let flat = @graph.flatten_images(tree)
  assert_true(@builder.verify_memory(flat).is_valid())
  assert_eq(@codec.decode_index(flat.index()).manifests.length(), 2)
  assert_true(flat.blob_count() < tree.blob_count())
}

///|
test "unknown media are reported without fetching their absent content" {
  let a = image("amd64")
  let index = @codec.decode_index(a.layout.index())
  let unknown = {
    ..a.report.manifest,
    digest: @model.Digest::sha256("0".repeat(64)),
    media_type: "application/example.unknown",
    size: 999L,
  }
  a.layout.set_index(
    @codec.encode_index({ ..index, manifests: [a.report.manifest, unknown], }),
  )
  let walk = @graph.walk_indexes(a.layout)
  assert_false(walk.complete)
  assert_eq(walk.skipped.length(), 1)
  let strict = try {
    ignore(@graph.flatten_images(a.layout))
    false
  } catch {
    _ => true
  }
  assert_true(strict)
  assert_true(
    @builder.verify_memory(@graph.flatten_images(a.layout, allow_skipped=true)).is_valid(),
  )
}

///|
test "traversal depth visits and metadata bytes are bounded" {
  let a = image("amd64")
  let tree = nest(nest(a.layout))
  for
    limits in [
      { ..@graph.WalkLimits::default(), max_depth: 1, },
      { ..@graph.WalkLimits::default(), max_visits: 1, },
      { ..@graph.WalkLimits::default(), max_metadata_bytes: 1L, },
    ] {
    let rejected = try {
      ignore(@graph.walk_indexes(tree, limits~))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}
