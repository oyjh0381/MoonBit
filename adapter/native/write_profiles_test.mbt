///|
async test "data-synchronous and explicit buffered publication preserve every content byte" {
  ensure_test_build_root()
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

///|
async test "concurrent layout writers leave exactly one intact publication" {
  ensure_test_build_root()
  let root = "_build/native-write-contention"
  if @fs.exists(root) {
    @fs.rmdir(root, recursive=true)
  }
  @fs.mkdir(root)
  defer @fs.rmdir(root, recursive=true)
  let destination = root + "/layout"
  let a = @layout.MemoryLayout::new()
  a.set_index(b"first")
  let first = a.put_blob("application/octet-stream", b"first content")
  let b = @layout.MemoryLayout::new()
  b.set_index(b"second")
  let second = b.put_blob("application/octet-stream", b"second content")
  async fn attempt(layout : @layout.MemoryLayout) -> Bool {
    try {
      @native.write_layout(destination, layout)
      true
    } catch {
      @model.IoFailure(_) => false
      error => raise error
    }
  }
  let outcomes = @async.all([() => attempt(a), () => attempt(b)])
  assert_true(outcomes[0] != outcomes[1])
  assert_false(@fs.exists(destination + ".moonoci-staging"))
  let result = @native.load_bounded_layout(destination)
  if outcomes[0] {
    assert_eq(result.index(), a.index())
    assert_eq(result.require_blob(first), b"first content")
  } else {
    assert_eq(result.index(), b.index())
    assert_eq(result.require_blob(second), b"second content")
  }
}
