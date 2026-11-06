///|
test "tree selection deduplicates aliases but refuses distinct platform matches" {
  let a = image("amd64")
  let root = @codec.decode_index(a.layout.index())
  a.layout.set_index(
    @codec.encode_index({
      ..root,
      manifests: [a.report.manifest, a.report.manifest],
    }),
  )
  let tree = nest(a.layout)
  let selected = @graph.select_image(tree, @model.default_platform())
  assert_true(@builder.verify_memory(selected).is_valid())
  assert_eq(@codec.decode_index(selected.index()).manifests.length(), 1)
  let other_request = @builder.default_single_layer_request([
    @archive.TarEntry::file("data", b"different"),
  ])
  let b = @builder.build_single_layer(other_request)
  for blob in b.layout.blob_records() {
    ignore(tree.put_blob(blob.descriptor().media_type, blob.data()))
  }
  let index = @codec.decode_index(tree.index())
  tree.set_index(
    @codec.encode_index({
      ..index,
      manifests: index.manifests + [b.report.manifest],
    }),
  )
  let ambiguous = try {
    ignore(@graph.select_image(tree, @model.default_platform()))
    false
  } catch {
    _ => true
  }
  assert_true(ambiguous)
}

///|
test "tree metadata quotas account shared objects once but count every traversal visit" {
  let a = image("amd64")
  let single = @graph.walk_indexes(a.layout)
  let root = @codec.decode_index(a.layout.index())
  a.layout.set_index(
    @codec.encode_index({
      ..root,
      manifests: [a.report.manifest, a.report.manifest],
    }),
  )
  let repeated = @graph.walk_indexes(a.layout)
  assert_eq(repeated.visits, 2)
  assert_eq(
    repeated.metadata_bytes - a.layout.index().length().to_int64(),
    single.metadata_bytes - @codec.encode_index(root).length().to_int64(),
  )
  let quota = try {
    ignore(
      @graph.walk_indexes(a.layout, limits={
        ..@graph.WalkLimits::default(),
        max_visits: 1,
      }),
    )
    false
  } catch {
    _ => true
  }
  assert_true(quota)
}
