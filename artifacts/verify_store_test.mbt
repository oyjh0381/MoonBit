///|
test "mixed store verification checks image and attachment payloads separately" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("data", b"image"),
    ]),
  )
  let bundle = @artifacts.attach(
    image.layout,
    image.report.manifest,
    "application/json",
    [{ media_type: "application/json", data: b"payload", annotations: [], }],
  )
  let valid = @artifacts.verify_store(bundle.layout, require_subject=true)
  assert_true(valid.valid)
  assert_eq(valid.images_checked, 1)
  assert_eq(valid.artifacts_checked, 1)
  assert_eq(valid.artifact_payload_bytes, 7L)
  let payload = @artifacts.inspect(bundle.layout, bundle.descriptor).manifest.payloads[0]
  let records = bundle.layout
    .blob_records()
    .map(blob => {
      (
        blob.descriptor(),
        if blob.descriptor().digest == payload.digest {
          b"damaged"
        } else {
          blob.data()
        },
      )
    })
  let corrupted = @layout.MemoryLayout::from_untrusted_parts(
    bundle.layout.marker(),
    bundle.layout.index(),
    records,
  )
  let invalid = @artifacts.verify_store(corrupted)
  assert_false(invalid.valid)
  assert_eq(invalid.images_checked, 1)
  assert_eq(invalid.artifacts_checked, 0)
}

///|
test "mixed store quota and unknown media block the profile with distinct findings" {
  let bundle = @artifacts.build("application/json", [
    { media_type: "application/json", data: b"larger", annotations: [], },
  ])
  let limited = @artifacts.verify_store(
    bundle.layout,
    max_total_payload_bytes=1L,
  )
  assert_false(limited.valid)
  let index = @codec.decode_index(bundle.layout.index())
  let unknown = {
    ..bundle.descriptor,
    media_type: "application/example.unknown",
    digest: @model.Digest::sha256("0".repeat(64)),
  }
  bundle.layout.set_index(
    @codec.encode_index({ ..index, manifests: index.manifests + [unknown], }),
  )
  let incomplete = @artifacts.verify_store(bundle.layout)
  assert_false(incomplete.valid)
  assert_false(incomplete.complete)
  assert_true(incomplete.findings.any(f => f.code == "unverified-media"))
}
