///|
pub let empty_media_type : String = "application/vnd.oci.empty.v1+json"

///|
/// OCI 1.1 artifact usage of the standard image-manifest media type.
pub(all) struct ArtifactManifest {
  artifact_type : String
  config : @model.Descriptor
  payloads : Array[@model.Descriptor]
  subject : @model.Descriptor?
  annotations : Array[@model.KeyValue]
}

///|
/// Validate the bare type/subtype name profile used by these artifact APIs.
pub fn validate_media_type(value : String) -> Unit raise @model.MoonOciError {
  let parts = value.split("/").collect()
  if parts.length() != 2 {
    raise @model.InvalidArgument("artifact media type requires type/subtype")
  }
  for part in parts {
    if part.is_empty() || part.length() > 127 {
      raise @model.InvalidArgument("invalid media type name length")
    }
    let mut first = true
    for ch in part {
      let alnum = (ch >= 'a' && ch <= 'z') ||
        (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9')
      if !alnum &&
        (first || !['!', '#', '$', '&', '-', '^', '_', '.', '+'].contains(ch)) {
        raise @model.InvalidArgument("invalid media type name character")
      }
      first = false
    }
  }
}

///|
fn quoted(value : String) -> String {
  Json::string(value).stringify()
}

///|
fn annotations_json(
  values : Array[@model.KeyValue],
) -> String raise @model.MoonOciError {
  let map : Map[String, String] = Map([])
  for item in values {
    if item.key.is_empty() || map.contains(item.key) {
      raise @model.InvalidArgument("empty or duplicate artifact annotation")
    }
    map[item.key] = item.value
  }
  let keys = map.keys().collect()
  keys.sort_by((a, b) => @pathing.compare_utf8(a, b))
  "{" + keys.map(key => quoted(key) + ":" + quoted(map[key])).join(",") + "}"
}

///|
pub fn encode_manifest(
  manifest : ArtifactManifest,
) -> Bytes raise @model.MoonOciError {
  validate_media_type(manifest.artifact_type)
  validate_media_type(manifest.config.media_type)
  for payload in manifest.payloads {
    validate_media_type(payload.media_type)
  }
  let fields = [
    "\"schemaVersion\":2",
    "\"mediaType\":" + quoted(@model.media_type_manifest),
    "\"artifactType\":" + quoted(manifest.artifact_type),
    "\"config\":" + @codec.encode_descriptor(manifest.config),
    "\"layers\":[" +
    manifest.payloads.map(d => @codec.encode_descriptor(d)).join(",") +
    "]",
  ]
  if manifest.subject is Some(subject) {
    fields.push("\"subject\":" + @codec.encode_descriptor(subject))
  }
  if !manifest.annotations.is_empty() {
    fields.push("\"annotations\":" + annotations_json(manifest.annotations))
  }
  @utf8.encode("{" + fields.join(",") + "}")
}

///|
pub fn decode_manifest(
  input : Bytes,
) -> ArtifactManifest raise @model.MoonOciError {
  let base = @codec.decode_manifest(input)
  if base.schema_version != 2 || base.media_type != @model.media_type_manifest {
    raise @model.InvalidOci("invalid artifact manifest schema/media type")
  }
  let fields = match @codec.parse_json_document(input) {
    Object(fields) => fields
    _ => raise @model.InvalidOci("artifact manifest must be an object")
  }
  let artifact_type = match fields.get("artifactType") {
    Some(String(value)) => value
    _ =>
      raise @model.InvalidOci(
        "artifactType is required by the artifact API profile",
      )
  }
  validate_media_type(artifact_type)
  validate_media_type(base.config.media_type)
  for payload in base.layers {
    validate_media_type(payload.media_type)
  }
  let subject = match fields.get("subject") {
    Some(value) => Some(@codec.decode_descriptor(value))
    None => None
  }
  {
    artifact_type,
    config: base.config,
    payloads: base.layers,
    subject,
    annotations: base.annotations,
  }
}
