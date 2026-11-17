///|
fn storage_fixture(
  contents : Bytes,
) -> @builder.BuildResult raise @model.MoonOciError {
  @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("payload", contents),
    ]),
  )
}

///|
test "ordered layer comparison accepts encoding changes and locates changed tar" {
  let before = storage_fixture(b"same")
  let rebuilt = @builder.transcode_image(
    before.layout,
    before.report.manifest.digest,
    @model.Gzip,
  )
  assert_true(
    @builder.compare_layer_order(
      before.layout,
      before.report.manifest.digest,
      rebuilt.layout,
      rebuilt.manifest.digest,
    )
    is None,
  )
  let changed = storage_fixture(b"different")
  guard @builder.compare_layer_order(
      before.layout,
      before.report.manifest.digest,
      changed.layout,
      changed.report.manifest.digest,
    )
    is Some(change) else {
    fail("expected first differing layer")
  }
  assert_eq(change.position, 0)
  assert_true(
    change.before_diff_id is Some(_) && change.after_diff_id is Some(_),
  )
}

///|
test "identical layers with distinct runtime configuration are not encoding-only" {
  let request = @builder.default_single_layer_request([
    @archive.TarEntry::file("payload", b"same"),
  ])
  let before = @builder.build_single_layer(request)
  let after = @builder.build_single_layer({
    ..request,
    author: Some("new author"),
  })
  let compared = @builder.compare_image_storage(
    before.layout,
    before.report.manifest.digest,
    after.layout,
    after.report.manifest.digest,
  )
  assert_true(compared.first_layer_difference is None)
  assert_true(compared.before_config != compared.after_config)
  assert_false(compared.preserves_runtime_identity())
}

///|
test "storage comparison counts one physical blob for repeated layer positions" {
  let layer : @builder.LayerBuildRequest = {
    entries: [@archive.TarEntry::file("repeated", b"storage")],
    remove: [],
    opaque_dirs: [],
    compression: @model.Uncompressed,
  }
  let before = @builder.build_image_from_layers(
    [Generated(layer), Generated(layer)],
    @model.default_platform(),
    @model.default_runtime_config(),
    "repeat",
  )
  let after = @builder.transcode_image(
    before.layout,
    before.report.manifest.digest,
    @model.Gzip,
    positions=[1],
  )
  let comparison = @builder.compare_image_storage(
    before.layout,
    before.report.manifest.digest,
    after.layout,
    after.manifest.digest,
  )
  assert_true(comparison.preserves_runtime_identity())
  assert_eq(comparison.before_layer_bytes, before.report.layers[0].size)
  assert_eq(comparison.after_layer_bytes, after.result_layer_bytes)
  guard @builder.compare_layer_order(
      before.layout,
      before.report.manifest.digest,
      storage_fixture(b"different").layout,
      storage_fixture(b"different").report.manifest.digest,
    )
    is Some(_) else {
    fail("expected unequal layer sequences")
  }
}
