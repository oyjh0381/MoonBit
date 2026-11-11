///|
fn plan_value(plan : RebasePlan) -> Json {
  let platform : Map[String, Json] = {
    "os": Json::string(plan.platform.os),
    "architecture": Json::string(plan.platform.architecture),
  }
  if plan.platform.variant is Some(value) {
    platform["variant"] = Json::string(value)
  }
  if plan.platform.os_version is Some(value) {
    platform["osVersion"] = Json::string(value)
  }
  {
    "schema": "moonoci.rebase-plan.v1",
    "application": Json::string(plan.pins.application.to_string()),
    "previousBase": Json::string(plan.pins.previous_base.to_string()),
    "replacementBase": Json::string(plan.pins.replacement_base.to_string()),
    "platform": Json::object(platform),
    "removedLayers": Json::number(plan.removed_layers.to_double()),
    "layers": Json::array(
      plan.layers.map(layer => {
        "digest": Json::string(layer.descriptor.digest.to_string()),
        "diffId": Json::string(layer.diff_id.to_string()),
        "mediaType": Json::string(layer.descriptor.media_type),
        "size": Json::string(layer.descriptor.size.to_string()),
        "fromReplacement": Json::boolean(layer.from_replacement),
      }),
    ),
  }
}

///|
pub fn plan_json(plan : RebasePlan) -> String {
  plan_value(plan).stringify()
}

///|
pub fn result_json(result : RebaseResult) -> String {
  let value : Json = {
    "schema": "moonoci.rebase-result.v1",
    "manifestDigest": Json::string(result.manifest.digest.to_string()),
    "indexDigest": Json::string(
      @digest.sha256(result.layout.index()).to_string(),
    ),
    "plan": plan_value(result.plan),
  }
  value.stringify()
}
