///|
test "transcoding preserves exact tar bytes and verifies storage and DiffID pins" {
  let result = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("data", b"hello"),
    ]),
  )
  let descriptor = result.report.layers[0]
  let raw = result.layout.require_blob(descriptor)
  let converted = @builder.transcode_layer_blob(
    descriptor,
    raw,
    descriptor.digest,
    @model.Gzip,
  )
  assert_eq(
    converted.data,
    @builder.transcode_layer_blob(
      descriptor,
      raw,
      descriptor.digest,
      @model.Gzip,
    ).data,
  )
  assert_eq(
    @builder.decode_layer_blob(converted.media_type, converted.data),
    raw,
  )
  assert_eq(converted.diff_id, descriptor.digest)
  assert_true(converted.digest != descriptor.digest)
  let gzip_descriptor = {
    ..descriptor,
    digest: converted.digest,
    size: converted.data.length().to_int64(),
    media_type: converted.media_type,
  }
  let same = @builder.transcode_layer_blob(
    gzip_descriptor,
    converted.data,
    descriptor.digest,
    @model.Gzip,
  )
  assert_eq(same.data, converted.data)
  let roundtrip = @builder.transcode_layer_blob(
    gzip_descriptor,
    converted.data,
    descriptor.digest,
    @model.Uncompressed,
  )
  assert_eq(roundtrip.data, raw)
  assert_eq(roundtrip.digest, descriptor.digest)
  let rejected = try {
    ignore(
      @builder.transcode_layer_blob(
        gzip_descriptor,
        converted.data,
        converted.digest,
        @model.Uncompressed,
      ),
    )
    false
  } catch {
    @model.DigestMismatch(_) => true
    _ => false
  }
  assert_true(rejected)
}
