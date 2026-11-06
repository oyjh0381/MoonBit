///|
test "catalog memoization still enforces deep alias paths and repeated sizes" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"image"),
    ]),
  )
  let source = image.layout
  let original = @codec.decode_index(source.index())
  let nested = source.put_blob(
    @model.media_type_index,
    @codec.encode_index(original),
  )
  let outer = source.put_blob(
    @model.media_type_index,
    @codec.encode_index({ ..original, manifests: [nested], }),
  )
  source.set_index(
    @codec.encode_index({ ..original, manifests: [nested, outer], }),
  )
  let pin = @digest.sha256(source.index())
  let limits = { ..@lifecycle.CatalogLimits::default(), max_depth: 2, }
  let rejected = try {
    ignore(@lifecycle.catalog(source, pin, limits~))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(
    @lifecycle.catalog(source, pin, limits={ ..limits, max_depth: 3, }).metadata_count(),
    3,
  )
  source.set_index(
    @codec.encode_index({
      ..original,
      manifests: [nested, { ..nested, size: nested.size + 1L, }],
    }),
  )
  let rejected = try {
    ignore(@lifecycle.catalog(source, @digest.sha256(source.index())))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "unknown advertised metadata blocks catalog rather than pretending closure complete" {
  let bundle = sample_store()
  let unknown = bundle.layout.put_blob("application/example.unknown", b"opaque")
  let root = @codec.decode_index(bundle.layout.index())
  bundle.layout.set_index(
    @codec.encode_index({ ..root, manifests: root.manifests + [unknown], }),
  )
  let rejected = try {
    ignore(
      @lifecycle.catalog(bundle.layout, @digest.sha256(bundle.layout.index())),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "weak external subject does not become a missing strong dependency" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"external"),
    ]),
  )
  let artifact = @artifacts.build(
    "application/json",
    [],
    subject=image.report.manifest,
  )
  let catalog = @lifecycle.catalog(
    artifact.layout,
    @digest.sha256(artifact.layout.index()),
  )
  assert_eq(catalog.metadata_count(), 1)
  assert_true(
    @lifecycle.catalog_json(catalog).contains(
      image.report.manifest.digest.to_string(),
    ),
  )
}
