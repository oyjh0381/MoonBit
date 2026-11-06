///|
test "manifest responses require caller pins but not optional Docker digest headers" {
  let body = b"{\"schemaVersion\":2,\"manifests\":[]}"
  let pin = @digest.sha256(body)
  let headers : Array[@model.KeyValue] = [
    { key: "CONTENT-Type", value: @model.media_type_index + "; charset=utf-8", },
    { key: "Content-Length", value: body.length().to_string(), },
  ]
  assert_eq(
    @registry.verify_manifest_response(200, headers, body, pin).digest,
    pin,
  )
  assert_eq(
    @registry.verify_manifest_response(
      200,
      headers + [{ key: "Docker-Content-Digest", value: pin.to_string(), }],
      body,
      pin,
    ).size,
    body.length().to_int64(),
  )
}

///|
test "ambiguous metadata encodings lengths and stale pins refuse response acceptance" {
  let body = b"{\"schemaVersion\":2,\"manifests\":[]}"
  let pin = @digest.sha256(body)
  let base : Array[@model.KeyValue] = [
    { key: "Content-Type", value: @model.media_type_index, },
  ]
  let cases : Array[Array[@model.KeyValue]] = [
    [{ key: "content-type", value: @model.media_type_index, }],
    [{ key: "Content-Length", value: "1", }],
    [{ key: "Content-Length", value: "2,2", }],
    [{ key: "Content-Length", value: "-1", }],
    [{ key: "Content-Encoding", value: "gzip", }],
    [
      {
        key: "Docker-Content-Digest",
        value: @digest.sha256(b"wrong").to_string(),
      },
    ],
    [{ key: "X-Test", value: "a\r\nb", }],
  ]
  for extra in cases {
    let rejected = try {
      ignore(@registry.verify_manifest_response(200, base + extra, body, pin))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  for status in [206, 301, 401, 404, 500] {
    let rejected = try {
      ignore(@registry.verify_manifest_response(status, base, body, pin))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  let mismatch = try {
    ignore(
      @registry.verify_manifest_response(
        200,
        base,
        body,
        @digest.sha256(b"stale"),
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(mismatch)
}

///|
test "opaque compressed OCI payloads are not HTTP decoded and remain quota bounded" {
  let body = b"\x1f\x8bopaque"
  let descriptor : @model.Descriptor = {
    media_type: @model.media_type_layer_gzip,
    digest: @digest.sha256(body),
    size: body.length().to_int64(),
    annotations: [],
    platform: None,
  }
  @registry.verify_blob_response(
    200,
    [{ key: "Content-Type", value: "application/octet-stream", }],
    body,
    descriptor,
  )
  let over = try {
    @registry.verify_blob_response(200, [], body, descriptor, max_bytes=1)
    false
  } catch {
    _ => true
  }
  assert_true(over)
  let truncated = try {
    @registry.verify_blob_response(200, [], b"short", descriptor)
    false
  } catch {
    _ => true
  }
  assert_true(truncated)
}
