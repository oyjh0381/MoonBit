///|
test "versioned policy preserves exact bytes and empty platform allowlists" {
  let defaults = @policy.decode_release_policy(b"{\"schemaVersion\":1}")
  assert_eq(defaults.max_manifests, 16)
  assert_true(defaults.require_numeric_nonroot)
  let custom = @policy.decode_release_policy(
    b"{\"schemaVersion\":1,\"maxManifests\":2,\"maxLayersPerImage\":3,\"maxReachableBytes\":\"9007199254740993\",\"allowedPlatforms\":[{\"os\":\"linux\",\"architecture\":\"arm64\",\"variant\":\"v8\"}],\"requireNumericNonroot\":false,\"requireCommand\":false,\"requiredLabels\":[\"team\"],\"forbiddenEnvNames\":[\"TOKEN\"]}",
  )
  assert_eq(custom.max_reachable_bytes, 9007199254740993L)
  assert_eq(custom.allowed_platforms.unwrap()[0].variant, Some("v8"))
  assert_false(custom.require_numeric_nonroot)
  assert_eq(custom.required_labels, ["team"])
  assert_eq(custom.forbidden_env_names, ["TOKEN"])
  assert_eq(
    @policy.decode_release_policy(
      b"{\"schemaVersion\":1,\"allowedPlatforms\":[]}",
    ).allowed_platforms,
    Some([]),
  )
}

///|
test "policy typos duplicates fractional counts and overflow fail closed" {
  for
    input in [
      "{}", "{\"schemaVersion\":2}", "{\"schemaVersion\":1,\"requireNonroot\":false}",
      "{\"schemaVersion\":1,\"schemaVersion\":1}", "{\"schemaVersion\":1,\"maxManifests\":1.5}",
      "{\"schemaVersion\":1,\"maxManifests\":1e2}", "{\"schemaVersion\":1,\"maxManifests\":2147483648}",
      "{\"schemaVersion\":1,\"maxManifests\":0}", "{\"schemaVersion\":1,\"requireCommand\":\"false\"}",
      "{\"schemaVersion\":1,\"maxReachableBytes\":9007199254740993}", "{\"schemaVersion\":1,\"maxReachableBytes\":\"9223372036854775808\"}",
      "{\"schemaVersion\":1,\"requiredLabels\":[\"x\",\"x\"]}", "{\"schemaVersion\":1,\"allowedPlatforms\":[{\"os\":\"linux\",\"architecture\":\"amd64\",\"osFeatures\":[]}]}",
      "{\"schemaVersion\":1,\"allowedPlatforms\":null}",
    ] {
    let rejected = try {
      ignore(@policy.decode_release_policy(@utf8.encode(input)))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}
