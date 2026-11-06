///|
test "registry style referrer pages retain and verify type subject and manifest metadata" {
  let subject = @artifacts.build("application/json", [])
  let attached = @artifacts.attach(
    subject.layout,
    subject.descriptor,
    "application/spdx+json",
    [],
    annotations=[{ key: "format", value: "spdx", }],
  )
  let discovery = @artifacts.referrers(
    attached.layout,
    subject.descriptor.digest,
  )
  let wire = @artifacts.referrers_json(discovery)
  let page = @artifacts.decode_referrer_page(@utf8.encode(wire))
  assert_eq(page[0].artifact_type, Some("application/spdx+json"))
  assert_true(
    @artifacts.verify_referrer_page(
      attached.layout,
      subject.descriptor.digest,
      page,
    ).valid,
  )
  let forged : Array[@artifacts.ReferrerAdvertisement] = [
    {
      artifact_type: Some("application/json"),
      descriptor: { ..page[0].descriptor, size: 1L, },
    },
  ]
  let invalid = @artifacts.verify_referrer_page(
    attached.layout,
    subject.descriptor.digest,
    forged,
    artifact_type="application/spdx+json",
  )
  assert_false(invalid.valid)
  assert_true(invalid.findings.any(f => f.code == "artifact-type-mismatch"))
  assert_true(invalid.findings.any(f => f.code == "descriptor-mismatch"))
}

///|
test "a valid empty referrer page is not a remote completeness assertion" {
  let subject = @artifacts.build("application/json", [])
  let page = @artifacts.decode_referrer_page(
    b"{\"schemaVersion\":2,\"manifests\":[]}",
  )
  assert_true(
    @artifacts.verify_referrer_page(
      subject.layout,
      subject.descriptor.digest,
      page,
    ).valid,
  )
}
