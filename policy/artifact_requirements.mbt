///|
pub(all) struct ArtifactRequirement {
  artifact_type : String
  minimum : Int32
  maximum : Int32
}

///|
pub(all) struct ArtifactRequirementDecision {
  allowed : Bool
  subject : @model.Digest
  verified_artifacts : Array[@model.Digest]
  findings : Array[PolicyFinding]
}

///|
/// Require verified, locally subject-bound attachments of caller-selected types.
/// Presence and content identity do not prove document semantics or signer trust.
pub fn evaluate_artifact_requirements(
  source : @layout.MemoryLayout,
  subject : @model.Digest,
  requirements : Array[ArtifactRequirement],
  limits~ : @artifacts.ArtifactLimits = @artifacts.ArtifactLimits::default(),
) -> ArtifactRequirementDecision raise @model.MoonOciError {
  if requirements.length() > 32 {
    raise @model.InvalidArgument("at most 32 artifact requirements")
  }
  let seen : Map[String, Bool] = Map([])
  for requirement in requirements {
    @artifacts.validate_media_type(requirement.artifact_type)
    if seen.contains(requirement.artifact_type) ||
      requirement.minimum < 1 ||
      requirement.maximum < requirement.minimum ||
      requirement.maximum > 128 {
      raise @model.InvalidArgument("invalid or duplicate artifact requirement")
    }
    seen[requirement.artifact_type] = true
  }
  let findings : Array[PolicyFinding] = []
  let verified : Array[@model.Digest] = []
  let discovery = @artifacts.referrers(source, subject) catch {
    error =>
      return {
        allowed: false,
        subject,
        verified_artifacts: [],
        findings: [
          {
            code: "artifact-discovery-failed",
            path: "index.json",
            message: error.message(),
          },
        ],
      }
  }
  if !discovery.complete {
    findings.push({
      code: "artifact-discovery-incomplete",
      path: "index.json",
      message: "unrecognized descriptors prevent a complete requirement check",
    })
  }
  for requirement in requirements {
    let candidates = discovery.referrers.filter(item => {
      item.artifact_type == Some(requirement.artifact_type)
    })
    if candidates.length() > requirement.maximum {
      findings.push({
        code: "artifact-count-exceeded",
        path: requirement.artifact_type,
        message: "matching referrers exceed the configured maximum",
      })
      continue
    }
    let mut count = 0
    for candidate in candidates {
      try {
        let observed = @artifacts.inspect(
          source,
          candidate.descriptor,
          limits~,
          require_subject=true,
        )
        if observed.manifest.artifact_type != requirement.artifact_type ||
          !observed.subject_present {
          raise @model.InvalidOci("required artifact type or subject mismatch")
        }
        count += 1
        verified.push(candidate.descriptor.digest)
      } catch {
        error =>
          findings.push({
            code: "artifact-content-invalid",
            path: candidate.descriptor.digest.to_string(),
            message: error.message(),
          })
      }
    }
    if count < requirement.minimum {
      findings.push({
        code: "artifact-required",
        path: requirement.artifact_type,
        message: "insufficient verified artifacts for the subject",
      })
    }
  }
  {
    allowed: findings.is_empty(),
    subject,
    verified_artifacts: verified,
    findings,
  }
}

///|
pub fn artifact_requirements_json(
  decision : ArtifactRequirementDecision,
) -> String {
  let findings : Array[Json] = decision.findings.map(f => {
    "code": Json::string(f.code),
    "path": Json::string(f.path),
    "message": Json::string(f.message),
  })
  let result : Json = {
    "schema": "moonoci.artifact-policy.v1",
    "allowed": Json::boolean(decision.allowed),
    "subject": Json::string(decision.subject.to_string()),
    "verified_artifacts": Json::array(
      decision.verified_artifacts.map(d => Json::string(d.to_string())),
    ),
    "findings": Json::array(findings),
  }
  result.stringify()
}
