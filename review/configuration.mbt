///|
pub(all) struct ConfigChange {
  field : String
  impact : String
}

///|
pub(all) struct ConfigComparison {
  changes : Array[ConfigChange]
  requires_review : Bool
}

///|
/// Report declared contract changes without exposing environment values. A
/// review classification is deliberately not a claim of runtime incompatibility.
pub fn compare_configuration(
  base : @model.ImageConfig,
  target : @model.ImageConfig,
) -> ConfigComparison {
  let changes : Array[ConfigChange] = []
  let add = fn(field : String, changed : Bool, impact : String) {
    if changed {
      changes.push({ field, impact, })
    }
  }
  add("platform", base.platform != target.platform, "review")
  add("config.User", base.runtime.user != target.runtime.user, "review")
  add(
    "config.Entrypoint",
    base.runtime.entrypoint != target.runtime.entrypoint,
    "review",
  )
  add("config.Cmd", base.runtime.cmd != target.runtime.cmd, "review")
  add(
    "config.WorkingDir",
    base.runtime.working_dir != target.runtime.working_dir,
    "review",
  )
  add("config.Env", base.runtime.env != target.runtime.env, "review")
  add(
    "config.StopSignal",
    base.runtime.stop_signal != target.runtime.stop_signal,
    "review",
  )
  add(
    "config.ExposedPorts",
    base.runtime.exposed_ports != target.runtime.exposed_ports,
    "review",
  )
  add(
    "config.Volumes",
    base.runtime.volumes != target.runtime.volumes,
    "review",
  )
  add("config.Labels", base.runtime.labels != target.runtime.labels, "metadata")
  add("created", base.created != target.created, "metadata")
  add("author", base.author != target.author, "metadata")
  add("history", base.history != target.history, "metadata")
  { changes, requires_review: changes.any(c => c.impact == "review"), }
}

///|
pub fn configuration_json(comparison : ConfigComparison) -> String {
  let changes : Array[Json] = comparison.changes.map(c => {
    "field": Json::string(c.field),
    "impact": Json::string(c.impact),
  })
  let result : Json = {
    "schema": "moonoci.config-comparison.v1",
    "requires_review": Json::boolean(comparison.requires_review),
    "changes": Json::array(changes),
  }
  result.stringify()
}
