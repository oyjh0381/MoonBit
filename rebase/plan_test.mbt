///|
fn layer(
  data : Bytes,
  path : String,
  compression : @model.Compression,
) -> @builder.LayerBuildRequest raise @model.MoonOciError {
  {
    entries: [@archive.TarEntry::file(path, data)],
    remove: [],
    opaque_dirs: [],
    compression,
  }
}

///|
fn image(
  layers : Array[@builder.LayerBuildRequest],
) -> @builder.ImageBuildResult raise @model.MoonOciError {
  @builder.build_image({
    layers,
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "fixture",
    annotations: [],
  })
}

///|
test "rebase plans match DiffIDs across compression and retain app layer bytes" {
  let old = image([layer(b"previous", "base", @model.Uncompressed)])
  let app = image([
    layer(b"previous", "base", @model.Gzip),
    layer(b"application", "app", @model.Uncompressed),
  ])
  let replacement = image([layer(b"updated", "base", @model.Uncompressed)])
  let pins : @rebase.RebasePins = {
    application: app.report.manifest.digest,
    previous_base: old.report.manifest.digest,
    replacement_base: replacement.report.manifest.digest,
  }
  assert_true(old.report.layers[0].digest != app.report.layers[0].digest)
  let plan = @rebase.plan_rebase(
    app.layout,
    old.layout,
    replacement.layout,
    pins,
  )
  assert_eq(plan.removed_layers, 1)
  assert_true(plan.layers[0].from_replacement)
  assert_eq(plan.layers[0].descriptor, replacement.report.layers[0])
  assert_false(plan.layers[1].from_replacement)
  assert_eq(plan.layers[1].descriptor, app.report.layers[1])
  let wrong = try {
    ignore(
      @rebase.plan_rebase(app.layout, replacement.layout, replacement.layout, {
        ..pins,
        previous_base: pins.replacement_base,
      }),
    )
    false
  } catch {
    @model.DigestMismatch(_) => true
    _ => false
  }
  assert_true(wrong)
}
