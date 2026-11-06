///|
test "registry paths follow separator grammar without accepting encoded traversal" {
  for name in ["a", "library/alpine", "team/a.b_c__d---e", "a0/b1"] {
    @registry.validate_repository(name)
  }
  for
    name in [
      "",
      "/a",
      "a/",
      "a//b",
      "../a",
      "a/..",
      "A/b",
      "a:b",
      "a%2Fb",
      "a?x=1",
      "a#b",
      "a\nb",
      "a___b",
      "a..b",
      "a.-b",
      "a_",
      "你/a",
      "a".repeat(256),
    ] {
    let rejected = try {
      @registry.validate_repository(name)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  let digest = @model.Digest::sha256("a".repeat(64))
  assert_eq(
    @registry.manifest_path("team/app", "V1.2_3-rc"),
    "/v2/team/app/manifests/V1.2_3-rc",
  )
  assert_eq(
    @registry.blob_path("team/app", digest),
    "/v2/team/app/blobs/sha256:" + "a".repeat(64),
  )
}

///|
test "tag bounds and query values cannot inject parameters" {
  for tag in ["_", "latest", "V1.0-rc", "a".repeat(128)] {
    @registry.validate_reference(tag)
  }
  for
    tag in [
      "",
      ".a",
      "-a",
      "a/b",
      "a b",
      "a?b",
      "a%20b",
      "a".repeat(129),
      "sha512:abc",
      "sha256:bad",
    ] {
    let rejected = try {
      @registry.validate_reference(tag)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  assert_eq(
    @registry.encode_query_value("a/b+c&x=1 中文"),
    "a%2Fb%2Bc%26x%3D1%20%E4%B8%AD%E6%96%87",
  )
  let digest = @model.Digest::sha256("b".repeat(64))
  assert_true(
    @registry.referrers_path(
      "a/b",
      digest,
      artifact_type="application/vnd.in-toto+json",
    ).has_suffix("?artifactType=application%2Fvnd.in-toto%2Bjson"),
  )
  assert_eq(
    @registry.tags_path("a/b", count=2, last="V1.0"),
    "/v2/a/b/tags/list?n=2&last=V1.0",
  )
}
