///|
fn release(
  runtime : @model.RuntimeConfig,
) -> @layout.MemoryLayout raise @model.MoonOciError {
  @builder.build_image({
    layers: [
      {
        entries: [@archive.TarEntry::file("app/data", b"hello")],
        remove: [],
        opaque_dirs: [],
        compression: @model.Uncompressed,
      },
    ],
    platform: @model.default_platform(),
    runtime,
    created: None,
    author: None,
    reference: "demo",
    annotations: [],
  }).layout
}

///|
test "release gate distinguishes caller policy from valid image structure" {
  let source = release(@model.default_runtime_config())
  assert_true(@builder.verify_memory(source).is_valid())
  let decision = @policy.evaluate(source)
  assert_false(decision.allowed)
  assert_true(decision.findings.any(f => f.code == "nonroot-user-required"))
  assert_true(decision.findings.any(f => f.code == "command-required"))
  let ready = release({
    ..@model.default_runtime_config(),
    user: Some("65532:65532"),
    entrypoint: ["/app/run"],
  })
  assert_true(@policy.evaluate(ready).allowed)
}

///|
test "release metadata constraints compose and emit structured decision paths" {
  let source = release({
    ..@model.default_runtime_config(),
    user: Some("root"),
    env: [{ key: "DEBUG", value: "1", }],
  })
  let result = @policy.evaluate(source, policy={
    ..@policy.ReleasePolicy::recommended(),
    allowed_platforms: Some([]),
    max_reachable_bytes: 1L,
    required_labels: ["org.opencontainers.image.source"],
    forbidden_env_names: ["DEBUG"],
  })
  for
    code in [
      "nonroot-user-required", "command-required", "platform-not-allowed", "content-size",
      "required-label", "forbidden-environment",
    ] {
    assert_true(result.findings.any(f => f.code == code))
  }
  assert_true(@policy.render_json(result).contains("moonoci.policy.v1"))
}

///|
test "nonroot policy refuses implicit named zero negative and overflowing UIDs" {
  for user in ["0", "000:1000", "root", "app", "-1", "18446744073709551616"] {
    let result = @policy.evaluate(
      release({
        ..@model.default_runtime_config(),
        user: Some(user),
        cmd: ["/run"],
      }),
    )
    assert_false(result.allowed)
  }
}

///|
test "invalid graph produces a blocked decision and invalid policy raises" {
  let source = @layout.MemoryLayout::new()
  assert_false(@policy.evaluate(source).allowed)
  let invalid = try {
    ignore(
      @policy.evaluate(source, policy={
        ..@policy.ReleasePolicy::recommended(),
        max_manifests: 0,
      }),
    )
    false
  } catch {
    _ => true
  }
  assert_true(invalid)
}
