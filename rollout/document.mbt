///|
fn document_fields(
  value : Json,
  allowed : Array[String],
) -> Map[String, Json] raise @model.MoonOciError {
  guard value is Object(fields) else {
    raise @model.InvalidArgument("rollout policy value must be an object")
  }
  for key, _ in fields {
    if !allowed.contains(key) {
      raise @model.InvalidArgument("unknown rollout policy field: " + key)
    }
  }
  fields
}

///|
fn document_required(
  fields : Map[String, Json],
  key : String,
) -> Json raise @model.MoonOciError {
  guard fields.get(key) is Some(value) else {
    raise @model.InvalidArgument("rollout policy requires " + key)
  }
  value
}

///|
fn document_text(
  value : Json,
  limit : Int32,
) -> String raise @model.MoonOciError {
  guard value is String(text) &&
    !text.is_empty() &&
    text.length() <= limit &&
    !text.contains_char('\u{0000}') else {
    raise @model.InvalidArgument("invalid rollout policy string")
  }
  text
}

///|
fn document_array(
  value : Json,
  limit : Int32,
) -> Array[Json] raise @model.MoonOciError {
  guard value is Array(values) && values.length() <= limit else {
    raise @model.InvalidArgument("invalid rollout policy array or count")
  }
  values
}

///|
fn document_flag(
  fields : Map[String, Json],
  key : String,
) -> Bool raise @model.MoonOciError {
  match fields.get(key) {
    None | Some(False) => false
    Some(True) => true
    _ =>
      raise @model.InvalidArgument(
        "rollout policy flag must be a boolean: " + key,
      )
  }
}

///|
fn document_platform(value : Json) -> @model.Platform raise @model.MoonOciError {
  let fields = document_fields(value, [
    "os", "architecture", "variant", "osVersion",
  ])
  {
    os: document_text(document_required(fields, "os"), 256),
    architecture: document_text(document_required(fields, "architecture"), 256),
    variant: fields.get("variant").map(value => document_text(value, 256)),
    os_version: fields.get("osVersion").map(value => document_text(value, 256)),
  }
}

///|
fn document_digest(
  fields : Map[String, Json],
  key : String,
) -> @model.Digest raise @model.MoonOciError {
  @model.Digest::parse(document_text(document_required(fields, key), 71))
}

///|
fn document_names(
  fields : Map[String, Json],
  key : String,
) -> Array[String] raise @model.MoonOciError {
  match fields.get(key) {
    None => []
    Some(value) =>
      document_array(value, 4096).map(item => document_text(item, 4096))
  }
}

///|
fn document_approval(
  value : Json,
) -> PlatformApproval raise @model.MoonOciError {
  let fields = document_fields(value, [
    "platform", "baselineManifest", "candidateManifest", "paths", "fields", "allowAdditions",
  ])
  {
    platform: document_platform(document_required(fields, "platform")),
    approval: {
      expected_base: document_digest(fields, "baselineManifest"),
      expected_target: document_digest(fields, "candidateManifest"),
      approved_paths: document_names(fields, "paths"),
      approved_fields: document_names(fields, "fields"),
      allow_additions: document_flag(fields, "allowAdditions"),
    },
  }
}

///|
/// Decode the bounded caller-owned rollout policy and fail on unknown fields,
/// duplicate object keys and unsupported schema versions.
pub fn decode_policy(input : Bytes) -> RolloutPolicy raise @model.MoonOciError {
  if input.length() > 65536 {
    raise @model.ResourceLimitExceeded("rollout policy exceeds 64 KiB")
  }
  let fields = document_fields(
    @codec.parse_json_document(input, preserve_number_repr=true),
    [
      "schemaVersion", "baselineIndex", "candidateIndex", "requiredPlatforms", "approvals",
      "allowNewPlatforms",
    ],
  )
  if document_required(fields, "schemaVersion").stringify() != "1" {
    raise @model.InvalidArgument("rollout policy schemaVersion must be 1")
  }
  let required = document_array(
    document_required(fields, "requiredPlatforms"),
    256,
  ).map(document_platform)
  if required.is_empty() {
    raise @model.InvalidArgument(
      "rollout policy requires at least one platform",
    )
  }
  let approvals = match fields.get("approvals") {
    None => []
    Some(value) =>
      document_array(value, required.length()).map(document_approval)
  }
  {
    baseline_index: document_digest(fields, "baselineIndex"),
    candidate_index: document_digest(fields, "candidateIndex"),
    required,
    approvals,
    allow_new_platforms: document_flag(fields, "allowNewPlatforms"),
  }
}
