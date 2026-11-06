///|
/// Host approvals are tied to both exact manifest digests, not reusable paths.
pub(all) struct UpgradeApproval {
  expected_base : @model.Digest
  expected_target : @model.Digest
  approved_paths : Array[String]
  approved_fields : Array[String]
  allow_additions : Bool
}

///|
pub(all) struct UpgradeDecision {
  allowed : Bool
  files : FileComparison
  configuration : ConfigComparison
  unreviewed_paths : Array[String]
  unreviewed_fields : Array[String]
}

///|
/// Recompute observations from pinned verified images. Passing records an
/// explicit host approval of observations, not proof of arbitrary consumer safety.
pub fn evaluate_upgrade(
  base : @layout.MemoryLayout,
  base_manifest : @model.Descriptor,
  target : @layout.MemoryLayout,
  target_manifest : @model.Descriptor,
  approval : UpgradeApproval,
) -> UpgradeDecision raise @model.MoonOciError {
  if approval.expected_base != base_manifest.digest ||
    approval.expected_target != target_manifest.digest {
    raise @model.DigestMismatch(
      "upgrade approval pins do not match the selected images",
    )
  }
  for group in [approval.approved_paths, approval.approved_fields] {
    if group.length() > 4096 {
      raise @model.InvalidArgument("at most 4096 approvals per group")
    }
    let seen : Map[String, Bool] = Map([])
    for value in group {
      if value.is_empty() || value.length() > 4096 || seen.contains(value) {
        raise @model.InvalidArgument("invalid or duplicate upgrade approval")
      }
      seen[value] = true
    }
  }
  let files = compare_files(base, base_manifest, target, target_manifest)
  let old = @codec.decode_manifest(base.require_blob(base_manifest))
  let next = @codec.decode_manifest(target.require_blob(target_manifest))
  let configuration = compare_configuration(
    @codec.decode_config(base.require_blob(old.config)),
    @codec.decode_config(target.require_blob(next.config)),
  )
  for path in approval.approved_paths {
    if !files.changes.any(c => c.path == path) {
      raise @model.InvalidArgument(
        "approval names an unchanged or missing path",
      )
    }
  }
  for field in approval.approved_fields {
    if !configuration.changes.any(c => c.field == field && c.impact == "review") {
      raise @model.InvalidArgument(
        "approval names an unchanged or nonruntime field",
      )
    }
  }
  let unreviewed_paths = files.changes
    .filter(c => {
      !(c.kind == "added" && approval.allow_additions) &&
      !approval.approved_paths.contains(c.path)
    })
    .map(c => c.path)
  let unreviewed_fields = configuration.changes
    .filter(c => {
      c.impact == "review" && !approval.approved_fields.contains(c.field)
    })
    .map(c => c.field)
  {
    allowed: unreviewed_paths.is_empty() && unreviewed_fields.is_empty(),
    files,
    configuration,
    unreviewed_paths,
    unreviewed_fields,
  }
}

///|
pub fn upgrade_json(decision : UpgradeDecision) -> String {
  let paths : Json = Json::array(decision.unreviewed_paths.map(Json::string))
  let fields : Json = Json::array(decision.unreviewed_fields.map(Json::string))
  "{\"schema\":\"moonoci.upgrade.v1\",\"allowed\":" +
  decision.allowed.to_string() +
  ",\"files\":" +
  files_json(decision.files) +
  ",\"configuration\":" +
  configuration_json(decision.configuration) +
  ",\"unreviewed_paths\":" +
  paths.stringify() +
  ",\"unreviewed_fields\":" +
  fields.stringify() +
  "}"
}
