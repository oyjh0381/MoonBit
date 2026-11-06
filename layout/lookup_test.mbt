///|
test "indexed content lookup preserves distinct blobs deduplication and insertion order" {
  let store = @layout.MemoryLayout::new()
  let descriptors : Array[@model.Descriptor] = []
  for i in 0..<2048 {
    let data = Bytes::from_array([i.to_byte(), (i >> 8).to_byte()])
    descriptors.push(store.put_blob("application/octet-stream", data))
  }
  assert_eq(store.blob_count(), 2048)
  for i in 0..<2048 {
    let data = Bytes::from_array([i.to_byte(), (i >> 8).to_byte()])
    assert_eq(store.get_blob(descriptors[i].digest), Some(data))
    assert_eq(
      store.put_blob("application/octet-stream", data).digest,
      descriptors[i].digest,
    )
    assert_eq(
      store.blob_records()[i].descriptor().digest,
      descriptors[i].digest,
    )
  }
  assert_eq(store.blob_count(), 2048)
}
