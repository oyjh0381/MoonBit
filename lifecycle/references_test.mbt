///|
test "resolve exact root names from the verified snapshot" {
  let built = @builder.build_single_layer(
    @builder.default_single_layer_request([@archive.TarEntry::file("app", b"x")]),
  )
  let root = @codec.decode_index(built.layout.index())
  let stable = {
    ..root.manifests[0],
    annotations: [{ key: @model.annotation_ref_name, value: "stable", }],
  }
  let candidate = {
    ..stable,
    annotations: [{ key: @model.annotation_ref_name, value: "candidate", }],
  }
  built.layout.set_index(
    @codec.encode_index({ ..root, manifests: [stable, stable, candidate], }),
  )
  let catalog = @lifecycle.catalog(
    built.layout,
    @digest.sha256(built.layout.index()),
  )
  built.layout.set_index(b"invalid")
  assert_eq(catalog.resolve_reference("stable"), stable)
  assert_eq(catalog.resolve_reference("candidate"), candidate)
  let plan = catalog.retain_references(["stable", "candidate"])
  assert_eq(plan.pin(), catalog.retain([stable.digest]).pin())
  assert_eq(plan.materialize().index(), catalog.snapshot().index())
  let duplicate = try {
    ignore(catalog.retain_references(["stable", "stable"]))
    false
  } catch {
    @model.InvalidArgument(_) => true
    _ => false
  }
  assert_true(duplicate)
  let missing = try {
    ignore(catalog.resolve_reference("Stable"))
    false
  } catch {
    @model.InvalidArgument(_) => true
    _ => false
  }
  assert_true(missing)
}

///|
test "reject a root name advertising two different manifests" {
  let a = @builder.build_single_layer(
    @builder.default_single_layer_request([@archive.TarEntry::file("app", b"a")]),
  )
  let b = @builder.build_single_layer(
    @builder.default_single_layer_request([@archive.TarEntry::file("app", b"b")]),
  )
  for record in b.layout.blob_records() {
    ignore(a.layout.put_blob(record.descriptor().media_type, record.data()))
  }
  let root = @codec.decode_index(a.layout.index())
  let annotations : Array[@model.KeyValue] = [
    { key: @model.annotation_ref_name, value: "stable", },
  ]
  a.layout.set_index(
    @codec.encode_index({
      ..root,
      manifests: [
        { ..a.report.manifest, annotations, },
        { ..b.report.manifest, annotations, },
      ],
    }),
  )
  let catalog = @lifecycle.catalog(a.layout, @digest.sha256(a.layout.index()))
  let ambiguous = try {
    ignore(catalog.resolve_reference("stable"))
    false
  } catch {
    @model.InvalidOci(_) => true
    _ => false
  }
  assert_true(ambiguous)
}
