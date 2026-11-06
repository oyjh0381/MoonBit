///|
test "complete local cache satisfies all requests with no accepted network bytes" {
  let source = image().layout
  let session = @registry.PullSession::new(
    "a",
    "tag",
    @digest.sha256(source.index()),
  )
  while session.next() is Some(request) {
    let bytes = if request.digest == @digest.sha256(source.index()) {
      source.index()
    } else {
      source.get_blob(request.digest).unwrap()
    }
    session.accept_cached(bytes)
  }
  assert_eq(session.cached_requests(), session.accepted_requests())
  assert_eq(session.accepted_network_bytes(), 0L)
  assert_eq(session.finish().index(), source.index())
  assert_true(
    @registry.pull_statistics_json(session).contains("\"complete\":true"),
  )
}

///|
test "a corrupt hit never advances or disguises itself as accepted cache data" {
  let source = image().layout
  let session = @registry.PullSession::new(
    "a",
    "tag",
    @digest.sha256(source.index()),
  )
  let bad = try {
    session.accept_cached(b"{}")
    false
  } catch {
    _ => true
  }
  assert_true(bad)
  assert_eq(session.cached_requests(), 0)
  assert_eq(session.accepted_requests(), 0)
  session.accept_cached(source.index())
  let pending = session.next().unwrap()
  let before = session.cached_bytes()
  let bad = try {
    session.accept_cached(b"bad")
    false
  } catch {
    _ => true
  }
  assert_true(bad)
  assert_eq(session.cached_bytes(), before)
  assert_eq(session.next().unwrap().digest, pending.digest)
  satisfy(session, source)
  assert_true(@builder.verify_memory(session.finish()).is_valid())
}
