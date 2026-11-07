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
  release_policy? : @policy.ReleasePolicy,
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
  let release_policy = release_policy.map(policy => {
    policy.validate()
    {
      ..policy,
      allowed_platforms: policy.allowed_platforms.map(values => values.copy()),
      required_labels: policy.required_labels.copy(),
      forbidden_env_names: policy.forbidden_env_names.copy(),
    }
  })
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
  let release = release_policy.map(policy => {
    @policy.evaluate_mixed(
      candidate.layout,
      policy~,
      graph_limits={
        max_depth: options.pull_limits.max_depth,
        max_visits: options.pull_limits.max_visits,
        max_metadata_bytes: options.pull_limits.max_total_bytes,
      },
      max_total_payload_bytes=options.pull_limits.max_total_bytes,
    )
  })
  let allowed = decision.allowed &&
    (match release {
      None => true
      Some(release) => release.allowed
    })
  let report : Json = {
    "schema": Json::string("moonoci.registry-admission.v1"),
    "eligible_for_publication": Json::boolean(allowed),
    "release_decision": match release {
      None => Json::null()
      Some(release) =>
        @codec.parse_json_document(
          @utf8.encode(@policy.mixed_release_json(release)),
        )
    },
    "acquisition": @codec.parse_json_document(
      @utf8.encode(candidate.statistics),
    ),
    "decision": @codec.parse_json_document(
      @utf8.encode(@policy.artifact_requirements_json(decision)),
    ),
  }
  {
    layout: if allowed {
      Some(candidate.layout)
    } else {
      None
    },
    statistics: report.stringify(),
  }
}
