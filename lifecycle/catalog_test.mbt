///|
fn sample_store() -> @artifacts.ArtifactBundle raise @model.MoonOciError {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"image"),
    ]),
  )
  @artifacts.attach(
    image.layout,
    image.report.manifest,
    "application/spdx+json",
    [{ media_type: "application/json", data: b"{}", annotations: [], }],
  )
}

///|
test "catalog snapshots mixed content and binds unadvertised physical membership" {
  let bundle = sample_store()
  let pin = @digest.sha256(bundle.layout.index())
  let first = @lifecycle.catalog(bundle.layout, pin)
  assert_eq(first.metadata_count(), 2)
  assert_eq(first.stored_blobs(), bundle.layout.blob_count())
  assert_eq(first.stored_bytes(), bundle.layout.blob_bytes())
  ignore(bundle.layout.put_blob("application/octet-stream", b"unused"))
  let second = @lifecycle.catalog(bundle.layout, pin)
  assert_eq(first.source_index(), second.source_index())
  assert_true(first.store_pin() != second.store_pin())
  assert_eq(second.stored_blobs(), first.stored_blobs() + 1)
}

///|
test "catalog rejects duplicates corrupt orphan content pins and quotas" {
  let bundle = sample_store()
  let pin = @digest.sha256(bundle.layout.index())
  let records = bundle.layout
    .blob_records()
    .map(b => (b.descriptor(), b.data()))
  let duplicate = @layout.MemoryLayout::from_untrusted_parts(
    bundle.layout.marker(),
    bundle.layout.index(),
    records + [records[0]],
  )
  let corrupt = @layout.MemoryLayout::from_untrusted_parts(
    bundle.layout.marker(),
    bundle.layout.index(),
    records +
    [
      (
        { ..records[0].0, digest: @digest.sha256(b"forged"), size: 4L, },
        b"nope",
      ),
    ],
  )
  for source in [duplicate, corrupt] {
    let rejected = try {
      ignore(@lifecycle.catalog(source, pin))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  let wrong_pin = try {
    ignore(@lifecycle.catalog(bundle.layout, @digest.sha256(b"wrong")))
    false
  } catch {
    _ => true
  }
  assert_true(wrong_pin)
  let over = try {
    ignore(
      @lifecycle.catalog(bundle.layout, pin, limits={
        ..@lifecycle.CatalogLimits::default(),
        max_stored_bytes: 1L,
      }),
    )
    false
  } catch {
    _ => true
  }
  assert_true(over)
}
