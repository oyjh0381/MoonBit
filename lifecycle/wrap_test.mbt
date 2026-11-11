///|
test "wrap a pinned root index without rewriting its child descriptors" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"image"),
    ]),
  )
  let raw = image.layout.index()
  let pin = @digest.sha256(raw)
  let original = @lifecycle.catalog(image.layout, pin)
  let wrapped = original.wrap_index("release")
  assert_eq(wrapped.blob_count(), image.layout.blob_count() + 1)
  assert_eq(wrapped.get_blob(pin), Some(raw))
  let named = @lifecycle.catalog(wrapped, @digest.sha256(wrapped.index()))
  assert_eq(named.resolve_reference("release").digest, pin)
  let closure = named.upload_closure("release")
  assert_eq(closure.manifests.map(d => d.digest), [
    image.report.manifest.digest,
    pin,
  ])
  assert_eq(image.layout.index(), raw)
  assert_eq(original.wrap_index("release"), wrapped)
}
