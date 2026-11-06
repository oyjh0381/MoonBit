///|
test "shared platform layers are fetched once and bad child responses do not advance" {
  let entries = [@archive.TarEntry::file("app", b"registry fixture")]
  let request = @builder.default_single_layer_request(entries)
  let first = @builder.build_single_layer(request)
  let second = @builder.build_single_layer({
    ..request,
    platform: { ..request.platform, architecture: "arm64", },
  })
  let source = @distribution.merge([first.layout, second.layout])
  let session = @registry.PullSession::new(
    "a",
    "tag",
    @digest.sha256(source.index()),
  )
  session.accept(
    200,
    response_headers(@model.media_type_index, source.index()),
    source.index(),
  )
  let pending = session.next().unwrap()
  let reserved = session.reserved_bytes()
  let accepted = session.accepted_requests()
  let body = source.get_blob(pending.digest).unwrap()
  let failed = try {
    session.accept(
      200,
      [
        { key: "Content-Type", value: @model.media_type_manifest, },
        { key: "Content-Length", value: "1", },
      ],
      body,
    )
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_eq(session.reserved_bytes(), reserved)
  assert_eq(session.accepted_requests(), accepted)
  satisfy(session, source)
  assert_eq(session.accepted_requests(), 6)
  assert_eq(session.finish().blob_count(), 5)
}

///|
test "root read budget respects total quota before a transport allocates bytes" {
  let source = image().layout
  let session = @registry.PullSession::new(
    "a",
    "tag",
    @digest.sha256(source.index()),
    limits={ ..@registry.PullLimits::default(), max_total_bytes: 1L, },
  )
  assert_eq(session.body_limit(), 1)
  let failed = try {
    session.accept(
      200,
      response_headers(@model.media_type_index, source.index()),
      source.index(),
    )
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_eq(session.reserved_bytes(), 0L)
}
