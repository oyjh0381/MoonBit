///|
test "index observations retain empty nested indexes and their source paths" {
  let source = @layout.MemoryLayout::new()
  let empty = @codec.encode_index({
    schema_version: 2,
    media_type: @model.media_type_index,
    manifests: [],
    annotations: [],
  })
  let descriptor = source.put_blob(@model.media_type_index, empty)
  source.set_index(
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests: [descriptor],
      annotations: [],
    }),
  )
  let walk = @graph.walk_indexes(source)
  assert_eq(walk.images.length(), 0)
  assert_eq(walk.indexes.length(), 1)
  assert_eq(walk.indexes[0].descriptor, descriptor)
  assert_eq(walk.indexes[0].index_path, [0])
  assert_true(walk.complete)
}
