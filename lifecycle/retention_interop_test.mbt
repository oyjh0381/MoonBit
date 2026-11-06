///|
test "rewritten roots preserve extension fields and exact number spellings" {
  let bundle = sample_store()
  let root = @codec.decode_index(bundle.layout.index())
  let descriptor = @codec.encode_descriptor(root.manifests[0])
  let extended = descriptor[0:descriptor.length() - 1].to_owned() +
    ",\"x-caller\":{\"serial\":9007199254740993,\"flags\":[true,false]}}"
  bundle.layout.set_index(
    @utf8.encode(
      "{\"schemaVersion\":2,\"mediaType\":\"" +
      @model.media_type_index +
      "\",\"x-decimal\":1.0000000000000000001,\"manifests\":[" +
      extended +
      "," +
      @codec.encode_descriptor(bundle.descriptor) +
      "]}",
    ),
  )
  let catalog = @lifecycle.catalog(
    bundle.layout,
    @digest.sha256(bundle.layout.index()),
  )
  let policy : @lifecycle.RetentionPolicy = {
    include_referrers: false,
    include_subjects: false,
  }
  let first = catalog.retain([root.manifests[0].digest], policy~).materialize()
  let again = catalog.retain([root.manifests[0].digest], policy~).materialize()
  assert_eq(first.index(), again.index())
  let text = @utf8.decode(first.index())
  assert_true(text.contains("9007199254740993"))
  assert_true(text.contains("1.0000000000000000001"))
  assert_true(text.contains("\"flags\":[true,false]"))
  assert_true(@artifacts.verify_store(first).valid)
}

///|
test "referrer policy follows attachment chains without pulling unrelated roots" {
  let bundle = sample_store()
  let second = @artifacts.attach(
    bundle.layout,
    bundle.descriptor,
    "application/vnd.in-toto+json",
    [],
  )
  let original = @codec.decode_index(bundle.layout.index())
  let image = original.manifests[0]
  let catalog = @lifecycle.catalog(
    second.layout,
    @digest.sha256(second.layout.index()),
  )
  let kept = catalog.retain([image.digest]).materialize()
  assert_eq(@codec.decode_index(kept.index()).manifests.length(), 3)
  assert_eq(
    @artifacts.referrers(kept, bundle.descriptor.digest).referrers.length(),
    1,
  )
  let image_only = catalog
    .retain([image.digest], policy={
      include_referrers: false,
      include_subjects: false,
    })
    .materialize()
  assert_eq(@codec.decode_index(image_only.index()).manifests.length(), 1)
  assert_true(@builder.verify_memory(image_only).is_valid())
}

///|
test "index subjects retain the exact original nested release bytes" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"image"),
    ]),
  )
  let release_bytes = image.layout.index()
  let subject = @artifacts.resolve_subject(
    image.layout,
    @digest.sha256(release_bytes),
  )
  let bundle = @artifacts.attach(
    image.layout,
    subject,
    "application/spdx+json",
    [],
  )
  let catalog = @lifecycle.catalog(
    bundle.layout,
    @digest.sha256(bundle.layout.index()),
  )
  let retained = catalog.retain([subject.digest]).materialize()
  assert_eq(retained.require_blob(subject), release_bytes)
  assert_eq(
    @artifacts.referrers(retained, subject.digest).referrers.length(),
    1,
  )
  assert_true(@artifacts.verify_store(retained).valid)
}
