///|
test "OCI Statement verification binds both the actual manifest link and payload subject" {
  let source = @artifacts.build("application/json", [])
  let target = source.descriptor
  let make_payload = fn(digest : @model.Digest) -> @artifacts.ArtifactPayload {
    let wire = "{\"_type\":\"https://in-toto.io/Statement/v1\",\"predicateType\":\"urn:build:v1\",\"subject\":[{\"digest\":{\"sha256\":\"" +
      digest.encoded +
      "\"}}]}"
    {
      media_type: @artifacts.statement_media_type,
      data: @utf8.encode(wire),
      annotations: [],
    }
  }
  let valid = @artifacts.attach(
    source.layout,
    target,
    @artifacts.statement_media_type,
    [make_payload(target.digest)],
  )
  let binding = @artifacts.verify_statement_attachment(
    valid.layout,
    valid.descriptor,
    target.digest,
    "urn:build:v1",
  )
  assert_eq(binding.subject, target.digest)
  assert_eq(binding.payload, @digest.sha256(make_payload(target.digest).data))
  let bad_payload = @artifacts.attach(
    source.layout,
    target,
    @artifacts.statement_media_type,
    [make_payload(@digest.sha256(b"other"))],
  )
  let bad_media = @artifacts.attach(source.layout, target, "application/json", [
    make_payload(target.digest),
  ])
  let two_payloads = @artifacts.attach(
    source.layout,
    target,
    @artifacts.statement_media_type,
    [make_payload(target.digest), make_payload(target.digest)],
  )
  let another_subject = @artifacts.attach(
    valid.layout,
    valid.descriptor,
    @artifacts.statement_media_type,
    [make_payload(target.digest)],
  )
  for bad in [bad_payload, bad_media, two_payloads, another_subject] {
    let rejected = try {
      ignore(
        @artifacts.verify_statement_attachment(
          bad.layout,
          bad.descriptor,
          target.digest,
          "urn:build:v1",
        ),
      )
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}
