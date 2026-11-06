///|
/// Caller-owned release constraints; metadata checks are not runtime isolation.
pub(all) struct ReleasePolicy {
  max_manifests : Int32
  max_layers_per_image : Int32
  max_reachable_bytes : Int64
  allowed_platforms : Array[@model.Platform]?
  require_numeric_nonroot : Bool
  require_command : Bool
  required_labels : Array[String]
  forbidden_env_names : Array[String]
}

///|
pub fn ReleasePolicy::recommended() -> ReleasePolicy {
  {
    max_manifests: 16,
    max_layers_per_image: 128,
    max_reachable_bytes: 536870912L,
    allowed_platforms: None,
    require_numeric_nonroot: true,
    require_command: true,
    required_labels: [],
    forbidden_env_names: [],
  }
}

///|
pub(all) struct PolicyFinding {
  code : String
  path : String
  message : String
}

///|
pub(all) struct PolicyDecision {
  allowed : Bool
  findings : Array[PolicyFinding]
  manifests_checked : Int32
  reachable_bytes : Int64
}

///|
/// Invalid configuration raises; invalid images produce a failed decision.
/// Every platform branch is checked. Source bytes and descriptors are untouched.
pub fn evaluate(
  source : @layout.MemoryLayout,
  policy~ : ReleasePolicy = ReleasePolicy::recommended(),
) -> PolicyDecision raise @model.MoonOciError {
  if policy.max_manifests < 1 ||
    policy.max_manifests > 4096 ||
    policy.max_layers_per_image < 1 ||
    policy.max_reachable_bytes < 1L ||
    policy.required_labels.length() > 64 ||
    policy.forbidden_env_names.length() > 64 {
    raise @model.InvalidArgument("invalid release policy limits")
  }
  for name in policy.required_labels + policy.forbidden_env_names {
    if name.is_empty() || name.length() > 256 {
      raise @model.InvalidArgument("invalid policy metadata key")
    }
  }
  let findings : Array[PolicyFinding] = []
  let add = fn(code : String, path : String, message : String) {
    findings.push({ code, path, message, })
  }
  let stats = @distribution.storage_inventory(source) catch {
    error => {
      add("invalid-image", "index.json", error.message())
      return {
        allowed: false,
        findings,
        manifests_checked: 0,
        reachable_bytes: 0L,
      }
    }
  }
  let index = @codec.decode_index(source.index())
  if index.manifests.is_empty() {
    add(
      "empty-distribution", "index.json.manifests", "release must contain an image",
    )
  }
  if index.manifests.length() > policy.max_manifests {
    add("manifest-count", "index.json.manifests", "manifest quota exceeded")
  }
  if stats.reachable_bytes > policy.max_reachable_bytes {
    add("content-size", "blobs", "reachable content quota exceeded")
  }
  for i, descriptor in index.manifests {
    let path = "index.json.manifests[" + i.to_string() + "]"
    let manifest = @codec.decode_manifest(source.require_blob(descriptor))
    let config = @codec.decode_config(source.require_blob(manifest.config))
    if policy.allowed_platforms is Some(allowed) {
      if !allowed.contains(config.platform) {
        add(
          "platform-not-allowed",
          path + ".platform",
          "platform not in caller allowlist",
        )
      }
    }
    if manifest.layers.length() > policy.max_layers_per_image {
      add("layer-count", path + ".layers", "layer quota exceeded")
    }
    let runtime = config.runtime
    if policy.require_numeric_nonroot && !numeric_nonroot(runtime.user) {
      add(
        "nonroot-user-required",
        path + ".config.User",
        "explicit nonzero numeric UID required",
      )
    }
    if policy.require_command &&
      runtime.entrypoint.is_empty() &&
      runtime.cmd.is_empty() {
      add("command-required", path + ".config", "Entrypoint or Cmd required")
    }
    for name in policy.required_labels {
      if !runtime.labels.any(item => {
          item.key == name && !item.value.trim().is_empty()
        }) {
        add("required-label", path + ".config.Labels", name)
      }
    }
    for name in policy.forbidden_env_names {
      if runtime.env.any(item => item.key == name) {
        add("forbidden-environment", path + ".config.Env", name)
      }
    }
  }
  {
    allowed: findings.is_empty(),
    findings,
    manifests_checked: index.manifests.length(),
    reachable_bytes: stats.reachable_bytes,
  }
}

///|
fn numeric_nonroot(user : String?) -> Bool {
  let uid = match user {
    None => return false
    Some(value) =>
      match value.split_once(":") {
        Some((name, _)) => name.to_owned()
        None => value
      }
  }
  if uid.is_empty() {
    return false
  }
  for ch in uid {
    if ch < '0' || ch > '9' {
      return false
    }
  }
  try @string.parse_int64(uid) > 0L catch {
    _ => false
  }
}

///|
pub fn render_json(decision : PolicyDecision) -> String {
  let findings : Array[Json] = decision.findings.map(f => {
    "code": Json::string(f.code),
    "path": Json::string(f.path),
    "message": Json::string(f.message),
  })
  let result : Json = {
    "schema": "moonoci.policy.v1",
    "allowed": Json::boolean(decision.allowed),
    "manifests_checked": Json::number(decision.manifests_checked.to_double()),
    "reachable_bytes": Json::string(decision.reachable_bytes.to_string()),
    "findings": Json::array(findings),
  }
  result.stringify()
}
