///|
test "platform coverage collapses identical aliases and checks exact variants" {
  let first = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"first"),
    ]),
  )
  let root = @codec.decode_index(first.layout.index())
  first.layout.set_index(
    @codec.encode_index({
      ..root,
      manifests: [root.manifests[0], root.manifests[0]],
    }),
  )
  let platform = @model.default_platform()
  let variant = { ..platform, variant: Some("v3"), }
  let coverage = @rollout.coverage(
    first.layout,
    @digest.sha256(first.layout.index()),
    [platform, variant],
  )
  if coverage.required[0].match_result is @rollout.Unique(digest) {
    assert_eq(digest, first.report.manifest.digest)
  } else {
    fail("identical aliases must produce one match")
  }
  assert_true(coverage.required[1].match_result is @rollout.Missing)
}

///|
test "platform coverage reports multiple distinct manifests independent of order" {
  let a = @builder.build_single_layer(
    @builder.default_single_layer_request([@archive.TarEntry::file("app", b"a")]),
  )
  let b = @builder.build_single_layer(
    @builder.default_single_layer_request([@archive.TarEntry::file("app", b"b")]),
  )
  for blob in b.layout.blob_records() {
    ignore(a.layout.put_blob(blob.descriptor().media_type, blob.data()))
  }
  let root = @codec.decode_index(a.layout.index())
  for
    manifests in [
      [a.report.manifest, b.report.manifest],
      [b.report.manifest, a.report.manifest],
    ] {
    a.layout.set_index(@codec.encode_index({ ..root, manifests, }))
    let coverage = @rollout.coverage(
      a.layout,
      @digest.sha256(a.layout.index()),
      [@model.default_platform()],
    )
    if coverage.required[0].match_result is @rollout.Ambiguous(digests) {
      let expected = [a.report.manifest.digest, b.report.manifest.digest]
      expected.sort_by((a, b) => a.to_string().compare(b.to_string()))
      assert_eq(digests, expected)
    } else {
      fail("different manifests must report a conflict")
    }
  }
}

///|
test "platform coverage preserves unknown-descriptor evidence and refuses a stale pin" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"test"),
    ]),
  )
  let original_pin = @digest.sha256(image.layout.index())
  let root = @codec.decode_index(image.layout.index())
  let unknown = image.layout.put_blob("application/example", b"unclassified")
  image.layout.set_index(
    @codec.encode_index({ ..root, manifests: root.manifests + [unknown], }),
  )
  let required = [@model.default_platform()]
  let coverage = @rollout.coverage(
    image.layout,
    @digest.sha256(image.layout.index()),
    required,
  )
  assert_eq(coverage.unknown_descriptors, 1)
  assert_true(coverage.required[0].match_result is @rollout.Unique(_))
  let stale = try {
    ignore(@rollout.coverage(image.layout, original_pin, required))
    false
  } catch {
    @model.DigestMismatch(_) => true
    _ => false
  }
  assert_true(stale)
}
