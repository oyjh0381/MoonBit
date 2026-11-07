///|
pub(all) struct RegistryAdmissionResult {
  layout : @layout.MemoryLayout?
  statistics : String
}

///|
pub(all) struct StatementRequirement {
  attachment : @model.Digest
  predicate_type : String
}

///|
fn statement_admission(
  layout : @layout.MemoryLayout,
  subject : @model.Digest,
  requirement : StatementRequirement,
) -> (Bool, Json) {
  let pin = Json::string(requirement.attachment.to_string())
  try {
    let descriptor = @artifacts.resolve_subject(layout, requirement.attachment)
    let binding = @artifacts.verify_statement_attachment(
      layout,
      descriptor,
      subject,
      requirement.predicate_type,
    )
    let observation = @codec.parse_json_document(
      @utf8.encode(@artifacts.statement_binding_json(binding)),
    )
    (
      true,
      {
        "allowed": Json::boolean(true),
        "attachment": pin,
        "binding": observation,
      },
    )
  } catch {
    error =>
      (
        false,
        {
          "allowed": Json::boolean(false),
          "attachment": pin,
          "code": Json::string(error.code()),
        },
      )
  }
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
  statement? : StatementRequirement,
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
  if statement is Some(requirement) {
    ignore(@model.Digest::parse(requirement.attachment.to_string()))
    @artifacts.validate_statement_predicate_type(requirement.predicate_type)
  }
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
  let (statement_allowed, statement_decision) = match statement {
    None => (true, Json::null())
    Some(requirement) =>
      statement_admission(candidate.layout, subject, requirement)
  }
  let allowed = decision.allowed &&
    statement_allowed &&
    (match release {
      None => true
      Some(release) => release.allowed
    })
  let report : Json = {
    "schema": Json::string("moonoci.registry-admission.v1"),
    "eligible_for_publication": Json::boolean(allowed),
    "statement_decision": statement_decision,
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
