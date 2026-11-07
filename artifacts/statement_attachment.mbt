///|
/// Verify a single raw Statement payload and its outer OCI subject binding.
/// The expected subject must resolve to metadata in this layout.
pub fn verify_statement_attachment(
  source : @layout.MemoryLayout,
  attachment : @model.Descriptor,
  subject : @model.Digest,
  predicate_type : String,
) -> StatementBinding raise @model.MoonOciError {
  validate_statement_predicate_type(predicate_type)
  let expected = resolve_subject(source, subject)
  let observed = inspect(source, attachment, limits={
    ..ArtifactLimits::default(),
    max_payloads: 1,
    max_payload_bytes: 1048576L,
  })
  if observed.manifest.artifact_type != statement_media_type ||
    observed.manifest.payloads.length() != 1 ||
    observed.manifest.payloads[0].media_type != statement_media_type {
    raise @model.InvalidOci(
      "attachment must carry one raw in-toto Statement payload",
    )
  }
  match observed.manifest.subject {
    Some(link) if link.digest == subject &&
      link.media_type == expected.media_type &&
      link.size == expected.size => ()
    _ =>
      raise @model.InvalidOci(
        "OCI attachment subject differs from expected metadata",
      )
  }
  let payload = source.require_blob(observed.manifest.payloads[0])
  verify_statement(payload, subject, predicate_type)
}

///|
pub fn statement_binding_json(binding : StatementBinding) -> String {
  let report : Json = {
    "schema": Json::string("moonoci.statement-binding.v1"),
    "subject": Json::string(binding.subject.to_string()),
    "payload": Json::string(binding.payload.to_string()),
    "predicate_type": Json::string(binding.predicate_type),
    "subjects_checked": Json::number(binding.subjects_checked.to_double()),
    "signatures_verified": Json::boolean(false),
  }
  report.stringify()
}
