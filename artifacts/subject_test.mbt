///|
test "release-index attachment preserves the exact pre-attachment subject bytes" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("data", b"image"),
    ]),
  )
  let before = image.layout.index()
  let pin = @digest.sha256(before)
  let subject = @artifacts.resolve_subject(image.layout, pin)
  assert_eq(subject.media_type, @model.media_type_index)
  let artifact = @artifacts.attach(
    image.layout,
    subject,
    "application/vnd.in-toto+json",
    [],
  )
  assert_eq(image.layout.index(), before)
  assert_eq(artifact.layout.require_blob(subject), before)
  assert_true(
    @codec.decode_index(artifact.layout.index()).manifests.any(d => {
      d.digest == pin && d.media_type == @model.media_type_index
    }),
  )
  assert_true(
    @artifacts.inspect(
      artifact.layout,
      artifact.descriptor,
      require_subject=true,
    ).subject_present,
  )
  assert_eq(@artifacts.referrers(artifact.layout, pin).referrers.length(), 1)
  let absent = try {
    ignore(
      @artifacts.resolve_subject(
        image.layout,
        @model.Digest::sha256("0".repeat(64)),
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(absent)
}
