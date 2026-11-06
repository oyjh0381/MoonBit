///|
fn config(runtime : @model.RuntimeConfig) -> @model.ImageConfig {
  {
    platform: @model.default_platform(),
    runtime,
    created: None,
    author: None,
    history: [],
    diff_ids: [],
  }
}

///|
test "configuration changes require review without leaking environment values" {
  let a = config(@model.default_runtime_config())
  let b = config({
    ..a.runtime,
    user: Some("65532"),
    entrypoint: ["/app/run"],
    env: [{ key: "TOKEN", value: "sensitive-fixture-value", }],
  })
  let comparison = @review.compare_configuration(a, b)
  assert_true(comparison.requires_review)
  assert_eq(comparison.changes.map(c => c.field), [
    "config.User", "config.Entrypoint", "config.Env",
  ])
  assert_false(
    @review.configuration_json(comparison).contains("sensitive-fixture-value"),
  )
  assert_false(@review.compare_configuration(a, a).requires_review)
}

///|
test "metadata changes are visible without claiming an execution contract change" {
  let a = config(@model.default_runtime_config())
  let b = {
    ..a,
    author: Some("maintainer"),
    created: Some("2026-11-06T00:00:00Z"),
  }
  let comparison = @review.compare_configuration(a, b)
  assert_false(comparison.requires_review)
  assert_eq(comparison.changes.map(c => c.field), ["created", "author"])
}
