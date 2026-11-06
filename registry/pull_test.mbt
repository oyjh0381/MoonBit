///|
fn image() -> @builder.BuildResult raise @model.MoonOciError {
  @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"registry fixture"),
    ]),
  )
}

///|
fn response_headers(media : String, body : Bytes) -> Array[@model.KeyValue] {
  [
    { key: "Content-Type", value: media, },
    { key: "Content-Length", value: body.length().to_string(), },
  ]
}

///|
fn satisfy(
  session : @registry.PullSession,
  source : @layout.MemoryLayout,
) -> Unit raise @model.MoonOciError {
  while session.next() is Some(request) {
    let body = match source.get_blob(request.digest) {
      Some(body) => body
      None =>
        if @digest.sha256(source.index()) == request.digest {
          source.index()
        } else {
          raise @model.InvalidOci("fixture does not contain request")
        }
    }
    let media = request.media_type.unwrap_or(@model.media_type_index)
    session.accept(200, response_headers(media, body), body)
  }
}

///|
test "portable pull stages a pinned graph and deduplicates shared content" {
  let source = image().layout
  let session = @registry.PullSession::new(
    "team/app",
    "stable",
    @digest.sha256(source.index()),
  )
  satisfy(session, source)
  let result = session.finish()
  assert_eq(result.index(), source.index())
  assert_eq(result.blob_count(), source.blob_count())
  assert_eq(session.accepted_requests(), 4)
  assert_eq(
    @builder.rootfs_from_layout(result),
    @builder.rootfs_from_layout(source),
  )
  result.set_index(b"{}")
  assert_eq(session.finish().index(), source.index())
}

///|
test "failed responses and closure reservations are atomic" {
  let source = image().layout
  let pin = @digest.sha256(source.index())
  let session = @registry.PullSession::new("a", "stable", pin)
  let bad = try {
    session.accept(200, response_headers(@model.media_type_index, b"{}"), b"{}")
    false
  } catch {
    _ => true
  }
  assert_true(bad)
  assert_eq(session.accepted_requests(), 0)
  assert_eq(session.reserved_bytes(), 0L)
  assert_eq(session.planned_requests(), 1)
  satisfy(session, source)
  assert_true(@builder.verify_memory(session.finish()).is_valid())
  let tiny = @registry.PullSession::new("a", "stable", pin, limits={
    ..@registry.PullLimits::default(),
    max_objects: 1,
  })
  let bad = try {
    tiny.accept(
      200,
      response_headers(@model.media_type_index, source.index()),
      source.index(),
    )
    false
  } catch {
    _ => true
  }
  assert_true(bad)
  assert_eq(tiny.accepted_requests(), 0)
  assert_eq(tiny.reserved_bytes(), 0L)
  assert_eq(tiny.planned_requests(), 1)
}

///|
test "manifest roots and weak external subjects produce standalone artifacts" {
  let image = image()
  let artifact = @artifacts.build(
    "application/json",
    [],
    subject=image.report.manifest,
  )
  let session = @registry.PullSession::new(
    "a",
    artifact.descriptor.digest.to_string(),
    artifact.descriptor.digest,
  )
  let body = artifact.layout.require_blob(artifact.descriptor)
  session.accept(200, response_headers(@model.media_type_manifest, body), body)
  satisfy(session, artifact.layout)
  let result = session.finish()
  assert_false(@artifacts.inspect(result, artifact.descriptor).subject_present)
  let incomplete = @registry.PullSession::new(
    "a",
    "tag",
    artifact.descriptor.digest,
  )
  let failed = try {
    ignore(incomplete.finish())
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}
