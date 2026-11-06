///|
test "origin normalization binds scheme hostname and effective port" {
  let first = @registry.RegistryOrigin::parse("HTTPS://Registry.Example:443/")
  let same = @registry.RegistryOrigin::parse("https://registry.example")
  assert_true(first.same_origin(same))
  assert_eq(first.url(), "https://registry.example")
  assert_false(
    first.same_origin(
      @registry.RegistryOrigin::parse("https://registry.example:444"),
    ),
  )
  assert_eq(
    @registry.RegistryOrigin::parse("http://127.0.0.1:80", allow_http=true).url(),
    "http://127.0.0.1",
  )
  for
    input in [
      "http://registry.example", "https://user:password@registry.example", "https://registry.example/path",
      "https://registry.example?x=1", "https://registry.example#frag", "https://registry.example\\evil",
      "https://registry.example:", "https://registry.example:0", "https://registry.example:65536",
      "https://2130706433", "https://127.01.0.1", "https://a..b", "https://a\nb",
      "https://K.example",
    ] {
    let rejected = try {
      ignore(@registry.RegistryOrigin::parse(input))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "IPv6 literals validate groups compression and embedded IPv4" {
  for
    address in [
      "::1", "::", "2001:db8::1", "1:2:3:4:5:6:7:8", "::ffff:192.0.2.128",
    ] {
    assert_eq(
      @registry.RegistryOrigin::parse("https://[" + address + "]:443").url(),
      "https://[" + address + "]",
    )
  }
  for
    address in [
      ":1", "1::2::3", ":::1", "1:2:3", "1:2:3:4:5:6:7:8:9", "12345::", "::1%25eth0",
      "::ffff:999.1.1.1",
    ] {
    let rejected = try {
      ignore(@registry.RegistryOrigin::parse("https://[" + address + "]"))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "URL resolution never inherits scheme-relative authorities or raw fragments" {
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  assert_eq(
    origin.request_url("/v2/a/manifests/latest").url(),
    "https://registry.example/v2/a/manifests/latest",
  )
  assert_eq(
    @registry.RegistryUrl::parse("https://auth.example?x=1").path(),
    "/?x=1",
  )
  assert_true(
    origin.resolve("/token?service=registry").origin().same_origin(origin),
  )
  assert_false(
    origin.resolve("https://other.example/blob").origin().same_origin(origin),
  )
  for
    path in [
      "//other.example/token", "/a#fragment", "/a b", "/a%", "/a%GG", "/a\\b", "/a\r\nb",
    ] {
    let rejected = try {
      ignore(origin.request_url(path))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}
