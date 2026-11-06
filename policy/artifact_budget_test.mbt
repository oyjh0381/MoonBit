///|
test "artifact requirements share an exact aggregate payload work allowance" {
  let subject = @artifacts.build("application/json", [])
  let one = @artifacts.attach(
    subject.layout,
    subject.descriptor,
    "application/json",
    [{ media_type: "application/json", data: b"123456", annotations: [], }],
  )
  let two = @artifacts.attach(
    one.layout,
    subject.descriptor,
    "application/json",
    [{ media_type: "application/json", data: b"abcdef", annotations: [], }],
  )
  let required : Array[@policy.ArtifactRequirement] = [
    { artifact_type: "application/json", minimum: 2, maximum: 2, },
  ]
  assert_true(
    @policy.evaluate_artifact_requirements(
      two.layout,
      subject.descriptor.digest,
      required,
      max_total_payload_bytes=12L,
    ).allowed,
  )
  let limited = @policy.evaluate_artifact_requirements(
    two.layout,
    subject.descriptor.digest,
    required,
    max_total_payload_bytes=11L,
  )
  assert_false(limited.allowed)
  assert_eq(limited.verified_artifacts.length(), 1)
  let invalid = try {
    ignore(
      @policy.evaluate_artifact_requirements(
        two.layout,
        subject.descriptor.digest,
        [],
        limits={ ..@artifacts.ArtifactLimits::default(), max_payloads: 0, },
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(invalid)
}
