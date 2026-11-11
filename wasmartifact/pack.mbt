///|
pub let config_media_type : String = "application/vnd.wasm.config.v0+json"

///|
pub let layer_media_type : String = "application/wasm"

///|
/// Component interface names supplied by the producer.
pub(all) struct ComponentMetadata {
  imports : Array[String]
  exports : Array[String]
  target : String?
}

///|
fn validate_interface_names(
  names : Array[String],
) -> Unit raise @model.MoonOciError {
  if names.length() > 4096 {
    raise @model.ResourceLimitExceeded("too many WebAssembly interface names")
  }
  let seen : Map[String, Bool] = Map([])
  for name in names {
    validate_interface_name(name)
    if seen.contains(name) {
      raise @model.InvalidArgument("repeated WebAssembly interface name")
    }
    seen[name] = true
  }
}

///|
fn validate_interface_name(name : String) -> Unit raise @model.MoonOciError {
  if name.is_empty() || name.length() > 1024 || name.contains_char('\u{0000}') {
    raise @model.InvalidArgument("invalid WebAssembly interface name")
  }
}

///|
fn component_json(
  metadata : ComponentMetadata,
) -> Json raise @model.MoonOciError {
  validate_interface_names(metadata.imports)
  validate_interface_names(metadata.exports)
  let fields : Map[String, Json] = {
    "imports": Json::array(metadata.imports.map(Json::string)),
    "exports": Json::array(metadata.exports.map(Json::string)),
  }
  if metadata.target is Some(target) {
    validate_interface_name(target)
    fields["target"] = Json::string(target)
  }
  Json::object(fields)
}

///|
/// Package a single Wasm binary according to the CNCF v0 OCI config profile.
/// Component metadata is supplied explicitly. For core modules, the profile
/// uses wasip1 even when the module itself imports no WASI functions.
pub fn pack(
  data : Bytes,
  reference : String,
  component? : ComponentMetadata,
) -> @artifacts.ArtifactBundle raise @model.MoonOciError {
  let limits = @artifacts.ArtifactLimits::default()
  if data.length().to_int64() > limits.max_payload_bytes {
    raise @model.ResourceLimitExceeded(
      "WebAssembly artifact payload exceeds 64 MiB",
    )
  }
  if reference.is_empty() ||
    reference.length() > 255 ||
    reference.contains_char('\u{0000}') {
    raise @model.InvalidArgument("invalid WebAssembly artifact reference")
  }
  let binary = inspect_binary(data)
  let (os, filename, metadata) = match (binary.kind, component) {
    (CoreModule, None) => ("wasip1", "module.wasm", None)
    (Component, Some(value)) =>
      ("wasip2", "component.wasm", Some(component_json(value)))
    _ =>
      raise @model.InvalidArgument(
        "component metadata must match the WebAssembly binary kind",
      )
  }
  let layout = @layout.MemoryLayout::new()
  let layer = layout.put_blob(layer_media_type, data, annotations=[
    { key: "org.opencontainers.image.title", value: filename, },
  ])
  let fields : Map[String, Json] = {
    "architecture": Json::string("wasm"),
    "os": Json::string(os),
    "layerDigests": Json::array([Json::string(layer.digest.to_string())]),
  }
  if metadata is Some(value) {
    fields["component"] = value
  }
  let config_bytes = @utf8.encode(Json::object(fields).stringify())
  if config_bytes.length() > limits.max_config_bytes {
    raise @model.ResourceLimitExceeded(
      "WebAssembly artifact configuration exceeds 1 MiB",
    )
  }
  let config = layout.put_blob(config_media_type, config_bytes)
  let descriptor = layout.put_blob(
    @model.media_type_manifest,
    @artifacts.encode_manifest({
      artifact_type: config_media_type,
      config,
      payloads: [layer],
      subject: None,
      annotations: [],
    }),
    annotations=[{ key: @model.annotation_ref_name, value: reference, }],
    platform={ architecture: "wasm", os, variant: None, os_version: None, },
  )
  layout.set_index(
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests: [descriptor],
      annotations: [],
    }),
  )
  { layout, descriptor, }
}
