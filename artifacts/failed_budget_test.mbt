///|
test "failed artifact payloads still reserve aggregate verification work budget" {
  let first = @artifacts.build("application/json", [
    { media_type: "application/json", data: b"abcdef", annotations: [], },
  ])
  let second = @artifacts.attach(
    first.layout,
    first.descriptor,
    "application/json",
    [{ media_type: "application/json", data: b"ghijkl", annotations: [], }],
  )
  let payload = @artifacts.inspect(first.layout, first.descriptor).manifest.payloads[0]
  let records = second.layout
    .blob_records()
    .map(b => {
      (
        b.descriptor(),
        if b.descriptor().digest == payload.digest {
          b"ABCDEF"
        } else {
          b.data()
        },
      )
    })
  let damaged = @layout.MemoryLayout::from_untrusted_parts(
    second.layout.marker(),
    second.layout.index(),
    records,
  )
  let report = @artifacts.verify_store(damaged, max_total_payload_bytes=8L)
  assert_false(report.valid)
  assert_eq(report.artifacts_checked, 0)
  assert_true(report.findings.any(f => f.code == "MOONOCI_RESOURCE_LIMIT"))
}
