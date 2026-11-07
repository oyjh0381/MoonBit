///|
pub(all) struct RegistryAdmissionResult {
  layout : @layout.MemoryLayout?
  statistics : String
}

///|
/// Combine acquisition with a caller-owned required-attachment gate before any
/// host publication. Rejected candidates return a decision and no layout.
pub async fn admit_registry_release(
  origin : String,
  repository : String,
  reference : String,
  expected : @model.Digest,
  subject : @model.Digest,
  requirements : Array[@policy.ArtifactRequirement],
  options~ : RegistryOptions = RegistryOptions::default(),
  discovery_limits~ : @registry.DiscoveryLimits = @registry.DiscoveryLimits::default(),
  cache? : @layout.MemoryLayout,
  bearer_token? : String,
) -> RegistryAdmissionResult {
  if requirements.is_empty() {
    raise @model.InvalidArgument(
      "registry admission requires at least one artifact requirement",
    )
  }
  @policy.validate_artifact_requirements(requirements)
  let requirements = requirements.copy()
  let candidate = pull_with_referrers(
    origin,
    repository,
    reference,
    expected,
    subject,
    options~,
    discovery_limits~,
    cache?,
    bearer_token?,
  )
  let decision = @policy.evaluate_artifact_requirements(
    candidate.layout,
    subject,
    requirements,
    max_total_payload_bytes=options.pull_limits.max_total_bytes,
  )
  let report : Json = {
    "schema": Json::string("moonoci.registry-admission.v1"),
    "eligible_for_publication": Json::boolean(decision.allowed),
    "acquisition": @codec.parse_json_document(
      @utf8.encode(candidate.statistics),
    ),
    "decision": @codec.parse_json_document(
      @utf8.encode(@policy.artifact_requirements_json(decision)),
    ),
  }
  {
    layout: if decision.allowed {
      Some(candidate.layout)
    } else {
      None
    },
    statistics: report.stringify(),
  }
}
