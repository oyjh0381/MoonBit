///|
test "single layer build creates and verifies a complete OCI layout" {
  let request = default_single_layer_request([
    @archive.TarEntry::directory("app"),
    @archive.TarEntry::file("app/hello.txt", b"hello MoonOCI\n"),
  ])
  let result = build_single_layer(request)
  assert_eq(result.layout.blob_count(), 3)
  assert_eq(result.report.layers.length(), 1)
  assert_true(result.layout.index().length() > 0)
  let report = verify_memory(result.layout)
  assert_true(report.is_valid())
  assert_eq(report.manifests_checked, 1)
  assert_eq(report.blobs_checked, 3)
  assert_eq(report.layers_checked, 1)
}

///|
test "identical single layer requests are reproducible" {
  let request = default_single_layer_request([
    @archive.TarEntry::file("file", b"content"),
  ])
  let first = build_single_layer(request)
  let second = build_single_layer(request)
  assert_eq(first.layout, second.layout)
  assert_eq(first.report, second.report)
}

///|
test "verification reports corrupted blob content" {
  let result = build_single_layer(
    default_single_layer_request([@archive.TarEntry::file("file", b"content")]),
  )
  let parts : Array[(@model.Descriptor, Bytes)] = []
  for index, blob in result.layout.blob_records() {
    parts.push(
      (blob.descriptor(), if index == 0 { b"tampered" } else { blob.data() }),
    )
  }
  let corrupted = @layout.MemoryLayout::from_untrusted_parts(
    result.layout.marker(),
    result.layout.index(),
    parts,
  )
  let report = verify_memory(corrupted)
  assert_false(report.is_valid())
  assert_eq(report.findings.length(), 1)
}
