///|
test "compaction removes unreachable content without changing the source or index" {
  let source = image("amd64", b"hello")
  let before = source.blob_count()
  ignore(source.put_blob("application/octet-stream", b"unused"))
  let stats = @distribution.storage_inventory(source)
  assert_eq(stats.reachable_blobs, before)
  assert_eq(stats.reclaimable_bytes, 6L)
  let compacted = @distribution.compact(source)
  assert_eq(compacted.blob_count(), before)
  assert_eq(source.blob_count(), before + 1)
  assert_eq(compacted.index(), source.index())
  assert_true(@builder.verify_memory(compacted).is_valid())
  assert_eq(@distribution.reachable_blobs(compacted).length(), before)
}

///|
test "storage accounting rejects duplicated physical records" {
  let source = image("amd64", b"hello")
  let records = source.blob_records().map(b => (b.descriptor(), b.data()))
  records.push(records[0])
  let duplicate = @layout.MemoryLayout::from_untrusted_parts(
    source.marker(),
    source.index(),
    records,
  )
  let rejected = try {
    ignore(@distribution.storage_inventory(duplicate))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
