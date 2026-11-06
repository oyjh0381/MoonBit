///|
test "Bearer requests downscope to pull and require explicit realm trust" {
  let challenge = @registry.parse_bearer_challenge(
    "Bearer realm=\"https://auth.example/token?tenant=a\",service=\"registry.example\",scope=\"repository:team/app:pull,push\"",
  )
  let registry = @registry.RegistryOrigin::parse("https://registry.example")
  let refused = try {
    ignore(challenge.token_request(registry, "team/app"))
    false
  } catch {
    _ => true
  }
  assert_true(refused)
  let request = challenge.token_request(registry, "team/app", allowed_realms=[
    @registry.RegistryOrigin::parse("https://auth.example"),
  ])
  assert_eq(
    request.url(),
    "https://auth.example/token?tenant=a&service=registry.example&scope=repository%3Ateam%2Fapp%3Apull",
  )
  let quoted = @registry.parse_bearer_challenge(
    "bEaReR realm=\"https://registry.example/token\", service=\"a,\\\"b\"",
  )
  assert_true(
    quoted.token_request(registry, "a").url().contains("service=a%2C%22b"),
  )
}

///|
test "Bearer challenge ambiguity and reserved realm queries cannot widen a request" {
  for
    value in [
      "Basic realm=\"https://a/token\"", "Bearer", "Bearer realm=\"x\",realm=\"y\"",
      "Bearer realm=\"x", "Bearer realm=\"x\",", "Bearer service=x", "Bearer realm=\"x\",service=\"bad\r\nvalue\"",
    ] {
    let rejected = try {
      ignore(@registry.parse_bearer_challenge(value))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  let registry = @registry.RegistryOrigin::parse("https://registry.example")
  for
    query in [
      "scope=x", "%73cope=x", "SERVICE=x", "offline_token=true", "x=1&x=2", "x=1;scope=x",
    ] {
    let challenge = @registry.parse_bearer_challenge(
      "Bearer realm=\"https://registry.example/token?" + query + "\"",
    )
    let rejected = try {
      ignore(challenge.token_request(registry, "a"))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  let downgrade = @registry.parse_bearer_challenge(
    "Bearer realm=\"http://registry.example/token\"",
  )
  let rejected = try {
    ignore(downgrade.token_request(registry, "a", allow_http=true))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "opaque tokens are bounded validated and never accept header injection" {
  assert_eq(
    @registry.decode_bearer_token(b"{\"token\":\"a.b_c-1\"}"),
    "Bearer a.b_c-1",
  )
  assert_eq(
    @registry.decode_bearer_token(b"{\"access_token\":\"YWJj==\"}"),
    "Bearer YWJj==",
  )
  for
    value in [
      b"{}", b"{\"token\":\"a\",\"access_token\":\"b\"}", b"{\"token\":\"a\\r\\nb\"}",
      b"{\"token\":\"a=b\"}", b"{\"token\":\"\"}", b"{\"token\":\"==\"}",
    ] {
    let rejected = try {
      ignore(@registry.decode_bearer_token(value))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}
