///|
async test "data-synchronous and explicit buffered publication preserve every content byte" {
  let root = "_build/native-write-profiles"
  if @fs.exists(root) {
    @fs.rmdir(root, recursive=true)
  }
  @fs.mkdir(root)
  let layout = @layout.MemoryLayout::new()
  layout.set_index(b"{\"schemaVersion\":2,\"manifests\":[]}")
  for i in 0..<64 {
    ignore(
      layout.put_blob(
        "application/octet-stream",
        Bytes::from_array([i.to_byte(), (i + 1).to_byte()]),
      ),
    )
  }
  for buffered in [false, true] {
    let path = root + "/buffered-" + buffered.to_string()
    @native.write_layout(path, layout, buffered~)
    let loaded = @native.load_bounded_layout(path)
    assert_eq(loaded.index(), layout.index())
    assert_eq(loaded.blob_count(), 64)
    for blob in layout.blob_records() {
      assert_eq(loaded.require_blob(blob.descriptor()), blob.data())
    }
  }
  let records = layout.blob_records().map(b => (b.descriptor(), b.data()))
  let invalid = @layout.MemoryLayout::from_untrusted_parts(
    layout.marker(),
    layout.index(),
    records + [records[0]],
  )
  let failed = try {
    @native.write_layout(root + "/duplicate", invalid)
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_false(@fs.exists(root + "/duplicate.moonoci-staging"))
  let forged : @model.Digest = { algorithm: "sha256", encoded: "../../escape", }
  let invalid = @layout.MemoryLayout::from_untrusted_parts(
    layout.marker(),
    layout.index(),
    [({ ..records[0].0, digest: forged, }, records[0].1)],
  )
  let failed = try {
    @native.write_layout(root + "/forged", invalid)
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_false(@fs.exists(root + "/forged.moonoci-staging"))
  @fs.rmdir(root, recursive=true)
}
