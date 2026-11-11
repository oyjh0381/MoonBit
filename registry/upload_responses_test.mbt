///|
test "registry publication reuses only a confirmed object" {
  let expected : @registry.PublishObject = {
    digest: @digest.sha256(b"data"),
    media_type: "application/octet-stream",
    data: b"data",
  }
  let headers : Array[@model.KeyValue] = [
    { key: "Content-Length", value: "4", },
    { key: "Docker-Content-Digest", value: expected.digest.to_string(), },
  ]
  assert_false(@registry.publication_exists(404, [], expected))
  assert_true(@registry.publication_exists(200, headers, expected))
  let wrong_size = try {
    ignore(
      @registry.publication_exists(200, headers, { ..expected, data: b"x", }),
    )
    false
  } catch {
    @model.SizeMismatch(_) => true
    _ => false
  }
  assert_true(wrong_size)
  let wrong_digest = try {
    ignore(
      @registry.publication_exists(200, headers, {
        ..expected,
        digest: @digest.sha256(b"else"),
      }),
    )
    false
  } catch {
    @model.DigestMismatch(_) => true
    _ => false
  }
  assert_true(wrong_digest)
}

///|
test "registry publication requires a matching creation receipt" {
  let expected = @digest.sha256(b"data")
  let headers : Array[@model.KeyValue] = [
    { key: "location", value: "/v2/team/app/blobs/" + expected.to_string(), },
    { key: "docker-content-digest", value: expected.to_string(), },
  ]
  @registry.check_publication_written(201, headers, expected)
  let missing = try {
    @registry.check_publication_written(201, [headers[0]], expected)
    false
  } catch {
    @model.InvalidOci(_) => true
    _ => false
  }
  assert_true(missing)
}
