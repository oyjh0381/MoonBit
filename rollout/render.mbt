///|
fn match_json(result : PlatformMatch) -> Json {
  let digests = match result {
    Missing => []
    Unique(digest) => [digest]
    Ambiguous(digests) => digests
  }
  Json::array(digests.map(digest => Json::string(digest.to_string())))
}

///|
fn platform_json(platform : @model.Platform) -> Json {
  let identity : Map[String, Json] = {
    "os": Json::string(platform.os),
    "architecture": Json::string(platform.architecture),
  }
  if platform.variant is Some(value) {
    identity["variant"] = Json::string(value)
  }
  if platform.os_version is Some(value) {
    identity["osVersion"] = Json::string(value)
  }
  Json::object(identity)
}

///|
fn row_json(row : PlatformDecision) -> Json {
  let transition = match row.pair.transition {
    Unavailable => "unavailable"
    Introduced => "introduced"
    Removed => "removed"
    Unchanged => "unchanged"
    Updated => "updated"
    AmbiguousMatch => "ambiguous"
  }
  let fields : Map[String, Json] = {
    "platform": platform_json(row.pair.platform),
    "baseline": match_json(row.pair.baseline),
    "candidate": match_json(row.pair.candidate),
    "transition": Json::string(transition),
    "allowed": Json::boolean(row.allowed),
  }
  if row.upgrade is Some(upgrade) {
    fields["files"] = {
      "added": Json::number(upgrade.files.added.to_double()),
      "removed": Json::number(upgrade.files.removed.to_double()),
      "modified": Json::number(upgrade.files.modified.to_double()),
    }
    fields["unreviewedPaths"] = Json::array(
      upgrade.unreviewed_paths.map(Json::string),
    )
    fields["unreviewedFields"] = Json::array(
      upgrade.unreviewed_fields.map(Json::string),
    )
  }
  Json::object(fields)
}

///|
/// Summarize the decision and reviewable names without exposing environment
/// values or file payloads.
pub fn rollout_json(decision : RolloutDecision) -> String {
  let value : Json = {
    "schema": "moonoci.rollout.v1",
    "baselineIndex": Json::string(
      decision.comparison.baseline_index.to_string(),
    ),
    "candidateIndex": Json::string(
      decision.comparison.candidate_index.to_string(),
    ),
    "baselineUnknownDescriptors": Json::number(
      decision.comparison.baseline_unknown.to_double(),
    ),
    "candidateUnknownDescriptors": Json::number(
      decision.comparison.candidate_unknown.to_double(),
    ),
    "baselineNonImageDescriptors": Json::number(
      decision.comparison.baseline_non_images.to_double(),
    ),
    "candidateNonImageDescriptors": Json::number(
      decision.comparison.candidate_non_images.to_double(),
    ),
    "baselineOmittedPlatforms": Json::array(
      decision.comparison.baseline_omitted.map(platform_json),
    ),
    "candidateOmittedPlatforms": Json::array(
      decision.comparison.candidate_omitted.map(platform_json),
    ),
    "allowed": Json::boolean(decision.allowed),
    "platforms": Json::array(decision.platforms.map(row_json)),
  }
  value.stringify()
}
