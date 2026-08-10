///|
test "gzip layer stores compressed digest and uncompressed DiffID" {
  let request = {
    ..default_single_layer_request([
      @archive.TarEntry::file("large.txt", @utf8.encode("repeat".repeat(100))),
    ]),
    compression: @model.Compression::Gzip,
  }
  let result = build_single_layer(request)
  let layer = result.report.layers[0]
  assert_eq(layer.media_type, @model.media_type_layer_gzip)
  let blob = result.layout.require_blob(layer)
  assert_eq(blob[0], b'\x1f')
  assert_eq(blob[1], b'\x8b')
  assert_eq(blob[4], b'\x00')
  assert_eq(blob[5], b'\x00')
  assert_eq(blob[6], b'\x00')
  assert_eq(blob[7], b'\x00')
  let config = @codec.decode_config(
    result.layout.require_blob(result.report.config),
  )
  assert_true(config.diff_ids[0] != layer.digest)
  assert_true(verify_memory(result.layout).is_valid())
}

///|
test "gzip builds are reproducible" {
  let request = {
    ..default_single_layer_request([
      @archive.TarEntry::file("data", b"deterministic"),
    ]),
    compression: @model.Compression::Gzip,
  }
  assert_eq(build_single_layer(request), build_single_layer(request))
}

///|
test "verification rejects corrupted gzip content" {
  let request = {
    ..default_single_layer_request([
      @archive.TarEntry::file("data", b"deterministic"),
    ]),
    compression: @model.Compression::Gzip,
  }
  let result = build_single_layer(request)
  for blob in result.layout.blobs {
    if blob.descriptor.media_type == @model.media_type_layer_gzip {
      let changed = blob.data.to_array()
      changed[changed.length() - 1] = changed[changed.length() - 1] ^ b'\x01'
      blob.data = Bytes::from_array(changed)
    }
  }
  assert_false(verify_memory(result.layout).is_valid())
}
