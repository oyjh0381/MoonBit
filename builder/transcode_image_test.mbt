///|
test "image transcode leaves config bytes and ordered filesystem identities intact" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("before", b"contents"),
    ]),
  )
  let result = @builder.transcode_image(
    image.layout,
    image.report.manifest.digest,
    @model.Gzip,
  )
  assert_eq(result.converted_layers, 1)
  let before = @builder.layer_chain_from_manifest(
    image.layout,
    image.report.manifest,
  )
  let after = @builder.layer_chain_from_manifest(result.layout, result.manifest)
  assert_true(after[0].descriptor.digest != before[0].descriptor.digest)
  assert_eq(after[0].chain_id, before[0].chain_id)
  assert_eq(after[0].diff_id, before[0].diff_id)
  assert_eq(
    result.layout.require_blob(image.report.config),
    image.layout.require_blob(image.report.config),
  )
  let repeated = @builder.transcode_image(
    result.layout,
    result.manifest.digest,
    @model.Gzip,
  )
  assert_eq(repeated.converted_layers, 0)
  assert_eq(repeated.manifest.digest, result.manifest.digest)
  let back = @builder.transcode_image(
    result.layout,
    result.manifest.digest,
    @model.Uncompressed,
  )
  assert_eq(back.manifest.digest, image.report.manifest.digest)
}

///|
test "transcode retains annotations and exact numeric extension values" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("file", b"data"),
    ]),
  )
  let layout = image.layout
  let original = image.report.manifest
  let index = @codec.decode_index(layout.index())
  let encoded = @codec.encode_descriptor(original)
  let extended = encoded[:encoded.length() - 1].to_owned() +
    ",\"x-serial\":9007199254740993}"
  let raw = "{\"schemaVersion\":2,\"mediaType\":\"" +
    index.media_type +
    "\",\"annotations\":{\"service\":\"test\"},\"manifests\":[" +
    extended +
    "]}"
  layout.set_index(@utf8.encode(raw))
  let result = @builder.transcode_image(layout, original.digest, @model.Gzip)
  let tag = @codec.decode_index(result.layout.index())
  assert_eq(tag.annotations, [{ key: "service", value: "test", }])
  assert_true(
    @utf8.decode_lossy(result.layout.index()).contains("9007199254740993"),
  )
  let unchanged = @builder.transcode_image(
    layout,
    original.digest,
    @model.Uncompressed,
  )
  assert_eq(unchanged.layout.index(), layout.index())
}

///|
test "selective transcode preserves storage of every unselected layer" {
  let base : @builder.LayerBuildRequest = {
    entries: [@archive.TarEntry::file("one", b"base")],
    remove: [],
    opaque_dirs: [],
    compression: @model.Uncompressed,
  }
  let top = { ..base, entries: [@archive.TarEntry::file("two", b"top")], }
  let image = @builder.build_image_from_layers(
    [Generated(base), Generated(top), Generated(base)],
    @model.default_platform(),
    @model.default_runtime_config(),
    "multi",
  )
  let changed = @builder.transcode_image(
    image.layout,
    image.report.manifest.digest,
    @model.Gzip,
    positions=[2],
  )
  let rows = @builder.layer_chain_from_manifest(
    changed.layout,
    changed.manifest,
  )
  assert_eq(changed.converted_layers, 1)
  assert_eq(rows[0].descriptor.digest, image.report.layers[0].digest)
  assert_eq(rows[1].descriptor.digest, image.report.layers[1].digest)
  assert_true(rows[2].descriptor.digest != image.report.layers[2].digest)
  assert_eq(rows[0].diff_id, rows[2].diff_id)
  let both = @builder.transcode_image(
    image.layout,
    image.report.manifest.digest,
    @model.Gzip,
    positions=[2, 0],
  )
  let rows = @builder.layer_chain_from_manifest(both.layout, both.manifest)
  assert_eq(both.converted_layers, 2)
  assert_eq(rows[0].descriptor.digest, rows[2].descriptor.digest)
  assert_eq(both.layout.blob_count(), 4)
  for positions in [[], [1, 1], [-1], [3]] {
    let rejected = try {
      ignore(
        @builder.transcode_image(
          image.layout,
          image.report.manifest.digest,
          @model.Gzip,
          positions~,
        ),
      )
      false
    } catch {
      @model.InvalidArgument(_) => true
      _ => false
    }
    assert_true(rejected)
  }
}
