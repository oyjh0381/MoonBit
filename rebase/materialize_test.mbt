///|
test "rebasing preserves application metadata and exact application layer bytes" {
  let base = image([layer(b"old", "base", @model.Uncompressed)])
  let app = image([
    layer(b"old", "base", @model.Gzip),
    layer(b"payload", "app", @model.Uncompressed),
  ])
  let replacement = image([
    layer(b"new", "base", @model.Gzip),
    layer(b"patched", "patch", @model.Uncompressed),
  ])
  let root = @codec.decode_index(app.layout.index())
  let manifest = @codec.decode_manifest(
    app.layout.require_blob(app.report.manifest),
  )
  guard @codec.parse_json_document(app.layout.require_blob(manifest.config))
    is Object(fields) else {
    fail("expected object")
  }
  fields["x-build-number"] = @codec.parse_json_document(
    b"9007199254740993",
    preserve_number_repr=true,
  )
  let config = app.layout.put_blob(
    @model.media_type_config,
    @utf8.encode(Json::object(fields).stringify()),
  )
  let app_manifest = app.layout.put_blob(
    @model.media_type_manifest,
    @codec.encode_manifest({ ..manifest, config, }),
  )
  app.layout.set_index(
    @codec.encode_index({ ..root, manifests: [app_manifest], }),
  )
  let original = app.layout.index()
  let pins : @rebase.RebasePins = {
    application: app_manifest.digest,
    previous_base: base.report.manifest.digest,
    replacement_base: replacement.report.manifest.digest,
  }
  let result = @rebase.rebase_image(
    app.layout,
    base.layout,
    replacement.layout,
    pins,
    "candidate",
    replacement_name="example.com/team/base:patched",
  )
  assert_eq(app.layout.index(), original)
  let emitted = @codec.decode_manifest(
    result.layout.require_blob(result.manifest),
  )
  assert_eq(emitted.layers, replacement.report.layers + [app.report.layers[1]])
  assert_eq(
    result.layout.require_blob(emitted.layers[2]),
    app.layout.require_blob(app.report.layers[1]),
  )
  let bytes = result.layout.require_blob(emitted.config)
  let parsed = @codec.decode_config(bytes)
  assert_eq(parsed.history.length(), 3)
  assert_true(
    @utf8.decode(bytes).contains("\"x-build-number\":9007199254740993"),
  )
  let contents = @builder.inventory_from_manifest(
    result.layout,
    result.manifest,
  )
  assert_eq(contents.map(item => item.entry.path), ["app", "base", "patch"])
  assert_eq(contents[1].content_digest, Some(@digest.sha256(b"new")))
  assert_true(
    emitted.annotations.any(item => {
      item.key == "org.opencontainers.image.base.digest" &&
      item.value == pins.replacement_base.to_string()
    }),
  )
  assert_eq(
    @rebase.rebase_image(
      app.layout,
      base.layout,
      replacement.layout,
      pins,
      "candidate",
      replacement_name="example.com/team/base:patched",
    ).layout,
    result.layout,
  )
}
