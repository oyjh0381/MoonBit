///|
test "rollout policy decoder binds exact platforms and rejects ambiguous documents" {
  let digest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  let platform = "{\"os\":\"linux\",\"architecture\":\"arm64\",\"variant\":\"v8\"}"
  let input = "{\"schemaVersion\":1,\"baselineIndex\":\"" +
    digest +
    "\",\"candidateIndex\":\"" +
    digest +
    "\",\"requiredPlatforms\":[" +
    platform +
    "]"
  let policy = @rollout.decode_policy(@utf8.encode(input + "}"))
  assert_eq(policy.required[0].variant, Some("v8"))
  assert_false(policy.allow_new_platforms)
  for
    suffix in [
      ",\"allowNewPlatforms\":\"true\"}", ",\"ignoreMissingPlatforms\":true}", ",\"schemaVersion\":1}",
    ] {
    let rejected = try {
      ignore(@rollout.decode_policy(@utf8.encode(input + suffix)))
      false
    } catch {
      @model.InvalidArgument(_) | @model.InvalidJson(_) => true
      _ => false
    }
    assert_true(rejected)
  }
}
