///|
fn referrer_fixture() -> (@model.Digest, Bytes, Bytes) raise @model.MoonOciError {
  let subject = @artifacts.build("application/json", [])
  let first = @artifacts.attach(
    subject.layout,
    subject.descriptor,
    "application/spdx+json",
    [],
  )
  let second = @artifacts.attach(
    subject.layout,
    subject.descriptor,
    "application/vnd.test.proof",
    [],
  )
  let pin = subject.descriptor.digest
  (
    pin,
    @utf8.encode(
      @artifacts.referrers_json(@artifacts.referrers(first.layout, pin)),
    ),
    @utf8.encode(
      @artifacts.referrers_json(@artifacts.referrers(second.layout, pin)),
    ),
  )
}

///|
test "paged referrers preserve filters and deduplicate identical overlap" {
  let (subject, first, second) = referrer_fixture()
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  let session = @registry.ReferrerSession::new(origin, "team/app", subject)
  let base = session.next_path().unwrap()
  let headers = response_headers(@model.media_type_index, first)
  headers.push({
    key: "Link",
    value: "<" + base + "?last=one>; title=\"a,b\"; rel=\"prev next\"",
  })
  session.accept(200, headers, first)
  assert_eq(session.next_path(), Some(base + "?last=one"))
  let headers = response_headers(@model.media_type_index, first)
  headers.push({
    key: "Link",
    value: "<https://registry.example" + base + "?last=two>; rel=next",
  })
  session.accept(200, headers, first)
  session.accept(200, response_headers(@model.media_type_index, second), second)
  assert_eq(session.pages(), 3)
  assert_eq(session.advertisements().length(), 2)
  let returned = session.advertisements()
  returned.clear()
  assert_eq(session.advertisements().length(), 2)
  let filtered = @registry.ReferrerSession::new(
    origin,
    "team/app",
    subject,
    artifact_type="application/spdx+json",
  )
  let headers = response_headers(@model.media_type_index, second)
  headers.push({ key: "Link", value: "<" + base + "?last=one>; rel=next", })
  filtered.accept(200, headers, second)
  assert_eq(
    filtered.next_path(),
    Some(base + "?last=one&artifactType=application%2Fspdx%2Bjson"),
  )
  filtered.accept(200, response_headers(@model.media_type_index, first), first)
  assert_eq(filtered.advertisements().length(), 1)
}

///|
test "referrer next links cannot move origin endpoint or filter" {
  let (subject, first, _) = referrer_fixture()
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  let base = @registry.referrers_path("app", subject)
  for
    link in [
      "<https://evil.example" + base + "?last=one>; rel=next",
      "<//evil.example" + base + ">; rel=next",
      "</v2/other/referrers/" + subject.to_string() + ">; rel=next",
      "<" + base + "?artifactType=application%2Fjson>; rel=next",
      "<" + base + "?last=one&last=two>; rel=next",
      "<" + base + "?%6east=one>; rel=next",
      "<" + base + "?n=-1>; rel=next",
      "<" + base + "?last=one>; rel=next; anchor=\"/other\"",
      "<" + base + "?last=one>; rel=next, <" + base + "?last=two>; rel=next",
      "<" + base + "?last=one>; rel=next; rel=next",
      "<" + base + "?last=one>; rel=\"next",
      "<?last=one>; rel=next",
      "<" + base + ">; rel=next",
    ] {
    let session = @registry.ReferrerSession::new(origin, "app", subject)
    let headers = response_headers(@model.media_type_index, first)
    headers.push({ key: "Link", value: link, })
    let rejected = try {
      session.accept(200, headers, first)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
    assert_eq(session.pages(), 0)
    assert_eq(session.next_path(), Some(base))
    session.accept(200, response_headers(@model.media_type_index, first), first)
    assert_eq(session.advertisements().length(), 1)
  }
}

///|
test "discovery enforces byte page and advertisement limits before mutation" {
  let (subject, first, second) = referrer_fixture()
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  let session = @registry.ReferrerSession::new(origin, "app", subject, limits={
    ..@registry.DiscoveryLimits::default(),
    max_pages: 1,
  })
  let headers = response_headers(@model.media_type_index, first)
  headers.push({
    key: "Link",
    value: "<" + session.next_path().unwrap() + "?last=one>; rel=next",
  })
  let rejected = try {
    session.accept(200, headers, first)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(session.received_bytes(), 0L)
  let session = @registry.ReferrerSession::new(origin, "app", subject, limits={
    ..@registry.DiscoveryLimits::default(),
    max_entries: 1,
  })
  session.accept(200, headers, first)
  let rejected = try {
    session.accept(
      200,
      response_headers(@model.media_type_index, second),
      second,
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(session.pages(), 1)
  let session = @registry.ReferrerSession::new(origin, "app", subject, limits={
    ..@registry.DiscoveryLimits::default(),
    max_total_bytes: first.length().to_int64() - 1L,
  })
  let rejected = try {
    session.accept(200, response_headers(@model.media_type_index, first), first)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(session.pages(), 0)
}

///|
test "discovery refuses conflicting overlap and forged digest headers" {
  let (subject, first, _) = referrer_fixture()
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  let session = @registry.ReferrerSession::new(origin, "app", subject)
  let headers = response_headers(@model.media_type_index, first)
  headers.push({
    key: "Link",
    value: "<" + session.next_path().unwrap() + "?last=one>; rel=next",
  })
  session.accept(200, headers, first)
  let changed = @utf8.encode(
    @utf8.decode(first).replace(
      old="application/spdx+json",
      new="application/vnd.changed",
    ),
  )
  let rejected = try {
    session.accept(
      200,
      response_headers(@model.media_type_index, changed),
      changed,
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(session.pages(), 1)
  let headers = response_headers(@model.media_type_index, first)
  headers.push({
    key: "Docker-Content-Digest",
    value: @digest.sha256(b"wrong").to_string(),
  })
  let rejected = try {
    session.accept(200, headers, first)
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  session.accept(200, response_headers(@model.media_type_index, first), first)
  assert_eq(session.advertisements().length(), 1)
}
