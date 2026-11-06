///|
test "required artifact policy distinguishes missing valid and corrupt attachments" {
  let image = release(@model.default_runtime_config())
  let subject = @codec.decode_index(image.index()).manifests[0]
  let requirements : Array[@policy.ArtifactRequirement] = [
    { artifact_type: "application/spdx+json", minimum: 1, maximum: 1, },
  ]
  assert_false(
    @policy.evaluate_artifact_requirements(image, subject.digest, requirements).allowed,
  )
  let bundle = @artifacts.attach(image, subject, "application/spdx+json", [
    { media_type: "application/json", data: b"payload", annotations: [], },
  ])
  let valid = @policy.evaluate_artifact_requirements(
    bundle.layout,
    subject.digest,
    requirements,
  )
  assert_true(valid.allowed)
  assert_eq(valid.verified_artifacts, [bundle.descriptor.digest])
  let payload = @artifacts.inspect(bundle.layout, bundle.descriptor).manifest.payloads[0]
  let records = bundle.layout
    .blob_records()
    .map(b => {
      (
        b.descriptor(),
        if b.descriptor().digest == payload.digest {
          b"damaged"
        } else {
          b.data()
        },
      )
    })
  let damaged = @layout.MemoryLayout::from_untrusted_parts(
    bundle.layout.marker(),
    bundle.layout.index(),
    records,
  )
  let invalid = @policy.evaluate_artifact_requirements(
    damaged,
    subject.digest,
    requirements,
  )
  assert_false(invalid.allowed)
  assert_true(invalid.findings.any(f => f.code == "artifact-content-invalid"))
}

///|
test "required artifact count limits and invalid policies are explicit" {
  let first = @artifacts.build("application/json", [])
  let second = @artifacts.attach(
    first.layout,
    first.descriptor,
    "application/json",
    [{ media_type: "text/plain", data: b"one", annotations: [], }],
  )
  let third = @artifacts.attach(
    second.layout,
    first.descriptor,
    "application/json",
    [{ media_type: "text/plain", data: b"two", annotations: [], }],
  )
  let result = @policy.evaluate_artifact_requirements(
    third.layout,
    first.descriptor.digest,
    [{ artifact_type: "application/json", minimum: 1, maximum: 1, }],
  )
  assert_false(result.allowed)
  assert_true(result.findings.any(f => f.code == "artifact-count-exceeded"))
  let invalid = try {
    ignore(
      @policy.evaluate_artifact_requirements(
        first.layout,
        first.descriptor.digest,
        [{ artifact_type: "application/json", minimum: 0, maximum: 1, }],
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(invalid)
}
