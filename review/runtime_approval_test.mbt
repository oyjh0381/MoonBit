///|
test "runtime changes require field approval tied to the exact candidate" {
  let layers : Array[@builder.LayerBuildRequest] = [
    {
      entries: [@archive.TarEntry::file("configuration", b"same")],
      remove: [],
      opaque_dirs: [],
      compression: @model.Uncompressed,
    },
  ]
  let request : @builder.ImageBuildRequest = {
    layers,
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "test",
    annotations: [],
  }
  let a = @builder.build_image(request)
  let b = @builder.build_image({
    ..request,
    runtime: { ..request.runtime, user: Some("65532"), },
  })
  let blocked = @review.evaluate_upgrade(
    a.layout,
    a.report.manifest,
    b.layout,
    b.report.manifest,
    pins(a, b),
  )
  assert_false(blocked.allowed)
  assert_eq(blocked.unreviewed_fields, ["config.User"])
  assert_eq(blocked.unreviewed_paths, [])
  let allowed = @review.evaluate_upgrade(
    a.layout,
    a.report.manifest,
    b.layout,
    b.report.manifest,
    { ..pins(a, b), approved_fields: ["config.User"], },
  )
  assert_true(allowed.allowed)
}

///|
test "duplicate approvals and approvals of metadata-only fields are invalid" {
  let a = snapshot([@archive.TarEntry::file("app", b"old")])
  let b = snapshot([@archive.TarEntry::file("app", b"new")])
  for
    approval in [
      { ..pins(a, b), approved_paths: ["app", "app"], },
      { ..pins(a, b), approved_fields: ["author"], },
    ] {
    let rejected = try {
      ignore(
        @review.evaluate_upgrade(
          a.layout,
          a.report.manifest,
          b.layout,
          b.report.manifest,
          approval,
        ),
      )
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}
