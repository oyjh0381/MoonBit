///|
test "download completion is distinct from supported semantic verification" {
  let source = image().layout
  let root = @codec.decode_index(source.index())
  let manifest = @codec.decode_manifest(source.require_blob(root.manifests[0]))
  let malformed = source.put_blob(@model.media_type_layer_tar, b"not a tar")
  let changed = source.put_blob(
    @model.media_type_manifest,
    @codec.encode_manifest({ ..manifest, layers: [malformed], }),
  )
  source.set_index(@codec.encode_index({ ..root, manifests: [changed], }))
  let session = @registry.PullSession::new(
    "a",
    "tag",
    @digest.sha256(source.index()),
  )
  satisfy(session, source)
  assert_true(session.next() is None)
  assert_false(session.is_verified())
  let failed = try {
    ignore(session.finish())
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_false(session.is_verified())
  assert_true(
    @registry.pull_statistics_json(session).contains("\"complete\":false"),
  )
  assert_true(
    @registry.pull_statistics_json(session).contains(
      "\"responses_complete\":true",
    ),
  )
}
