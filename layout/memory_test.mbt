///|
test "memory layout deduplicates identical blobs" {
  let layout = MemoryLayout::new()
  let first = layout.put_blob(@model.media_type_config, b"same")
  let second = layout.put_blob(@model.media_type_config, b"same")
  assert_eq(first, second)
  assert_eq(layout.blob_count(), 1)
  assert_eq(layout.require_blob(first), b"same")
}

///|
test "memory layout detects descriptor size mismatch" {
  let layout = MemoryLayout::new()
  let descriptor = layout.put_blob(@model.media_type_config, b"content")
  let wrong : @model.Descriptor = { ..descriptor, size: descriptor.size + 1L }
  let mut raised = false
  ignore(layout.require_blob(wrong)) catch {
    _ => raised = true
  }
  assert_true(raised)
}
