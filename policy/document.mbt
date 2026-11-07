///|
fn policy_object(
  value : Json,
  allowed : Array[String],
) -> Map[String, Json] raise @model.MoonOciError {
  let fields = match value {
    Object(fields) => fields
    _ => raise @model.InvalidArgument("policy value must be an object")
  }
  for key, _ in fields {
    if !allowed.contains(key) {
      raise @model.InvalidArgument("unknown policy field: " + key)
    }
  }
  fields
}

///|
fn policy_integer(
  fields : Map[String, Json],
  name : String,
  default : Int32,
) -> Int32 raise @model.MoonOciError {
  match fields.get(name) {
    None => default
    Some(Number(_) as value) => {
      let text = value.stringify()
      if !text.to_array().all(ch => ch >= '0' && ch <= '9') {
        raise @model.InvalidArgument(
          "policy count requires an unsigned decimal integer token",
        )
      }
      @string.parse_int(text) catch {
        _ => raise @model.InvalidArgument("policy integer overflows Int32")
      }
    }
    _ => raise @model.InvalidArgument("policy count must be a JSON integer")
  }
}

///|
fn policy_bool(
  fields : Map[String, Json],
  name : String,
  default : Bool,
) -> Bool raise @model.MoonOciError {
  match fields.get(name) {
    None => default
    Some(True) => true
    Some(False) => false
    _ => raise @model.InvalidArgument("policy flag must be a boolean")
  }
}

///|
fn policy_text(value : Json) -> String raise @model.MoonOciError {
  match value {
    String(value) if !value.is_empty() &&
      value.length() <= 256 &&
      !value.to_array().any(ch => ch < ' ' || ch == '\u{007f}') => value
    _ =>
      raise @model.InvalidArgument(
        "policy string must contain 1..256 non-control characters",
      )
  }
}

///|
fn policy_names(
  fields : Map[String, Json],
  name : String,
) -> Array[String] raise @model.MoonOciError {
  let values = match fields.get(name) {
    None => return []
    Some(Array(values)) => values
    _ => raise @model.InvalidArgument("policy names must be an array")
  }
  if values.length() > 64 {
    raise @model.InvalidArgument("policy name list exceeds 64")
  }
  let seen : Map[String, Bool] = Map([])
  values.map(value => {
    let name = policy_text(value)
    if seen.contains(name) {
      raise @model.InvalidArgument("duplicate policy metadata name")
    }
    seen[name] = true
    name
  })
}

///|
/// Strict versioned policy. Counts are unsigned integer JSON tokens; the Int64
/// byte budget is a decimal string to avoid numeric rounding.
pub fn decode_release_policy(
  input : Bytes,
) -> ReleasePolicy raise @model.MoonOciError {
  if input.length() > 65536 {
    raise @model.ResourceLimitExceeded("release policy exceeds 64 KiB")
  }
  let fields = policy_object(
    @codec.parse_json_document(input, preserve_number_repr=true),
    [
      "schemaVersion", "maxManifests", "maxLayersPerImage", "maxReachableBytes",
      "allowedPlatforms", "requireNumericNonroot", "requireCommand", "requiredLabels",
      "forbiddenEnvNames",
    ],
  )
  if !fields.contains("schemaVersion") ||
    policy_integer(fields, "schemaVersion", 0) != 1 {
    raise @model.InvalidArgument("release policy schemaVersion must be 1")
  }
  let defaults = ReleasePolicy::recommended()
  let bytes = match fields.get("maxReachableBytes") {
    None => defaults.max_reachable_bytes
    Some(String(value)) if !value.is_empty() &&
      value.to_array().all(ch => ch >= '0' && ch <= '9') =>
      @string.parse_int64(value) catch {
        _ =>
          raise @model.InvalidArgument(
            "release policy byte budget overflows Int64",
          )
      }
    _ =>
      raise @model.InvalidArgument(
        "maxReachableBytes requires a decimal string",
      )
  }
  let platforms = match fields.get("allowedPlatforms") {
    None => None
    Some(Array(values)) => {
      if values.length() > 256 {
        raise @model.InvalidArgument("policy platform list exceeds 256")
      }
      let platforms : Array[@model.Platform] = []
      for value in values {
        let fields = policy_object(value, [
          "os", "architecture", "variant", "osVersion",
        ])
        let os = match fields.get("os") {
          Some(value) => policy_text(value)
          None => raise @model.InvalidArgument("policy platform needs os")
        }
        let architecture = match fields.get("architecture") {
          Some(value) => policy_text(value)
          None =>
            raise @model.InvalidArgument("policy platform needs architecture")
        }
        let platform : @model.Platform = {
          os,
          architecture,
          variant: fields.get("variant").map(policy_text),
          os_version: fields.get("osVersion").map(policy_text),
        }
        if platforms.contains(platform) {
          raise @model.InvalidArgument("duplicate policy platform")
        }
        platforms.push(platform)
      }
      Some(platforms)
    }
    _ => raise @model.InvalidArgument("allowedPlatforms must be an array")
  }
  let policy : ReleasePolicy = {
    max_manifests: policy_integer(
      fields,
      "maxManifests",
      defaults.max_manifests,
    ),
    max_layers_per_image: policy_integer(
      fields,
      "maxLayersPerImage",
      defaults.max_layers_per_image,
    ),
    max_reachable_bytes: bytes,
    allowed_platforms: platforms,
    require_numeric_nonroot: policy_bool(
      fields,
      "requireNumericNonroot",
      defaults.require_numeric_nonroot,
    ),
    require_command: policy_bool(
      fields,
      "requireCommand",
      defaults.require_command,
    ),
    required_labels: policy_names(fields, "requiredLabels"),
    forbidden_env_names: policy_names(fields, "forbiddenEnvNames"),
  }
  policy.validate()
  policy
}
