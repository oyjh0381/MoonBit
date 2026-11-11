///|
pub(all) struct WasmArtifact {
  manifest : @model.Descriptor
  binary : BinarySummary
  config : @model.Descriptor
  layer : @model.Descriptor
  data : Bytes
  component : ComponentMetadata?
}

///|
fn read_names(
  fields : Map[String, Json],
  key : String,
) -> Array[String] raise @model.MoonOciError {
  guard fields.get(key) is Some(Array(values)) else {
    raise @model.InvalidOci("WebAssembly component requires " + key)
  }
  let names = values.map(value => {
    match value {
      String(name) => name
      _ =>
        raise @model.InvalidOci("WebAssembly interface name must be a string")
    }
  })
  validate_interface_names(names)
  names
}

///|
fn read_component(value : Json) -> ComponentMetadata raise @model.MoonOciError {
  guard value is Object(fields) else {
    raise @model.InvalidOci("WebAssembly component metadata must be an object")
  }
  let target = match fields.get("target") {
    None => None
    Some(String(name)) => {
      validate_interface_name(name)
      Some(name)
    }
    _ =>
      raise @model.InvalidOci("WebAssembly component target must be a string")
  }
  {
    imports: read_names(fields, "imports"),
    exports: read_names(fields, "exports"),
    target,
  }
}

///|
/// Decode a producer-supplied component interface document.
pub fn decode_component_metadata(
  data : Bytes,
) -> ComponentMetadata raise @model.MoonOciError {
  if data.length() > @artifacts.ArtifactLimits::default().max_config_bytes {
    raise @model.ResourceLimitExceeded(
      "component interface document exceeds 1 MiB",
    )
  }
  read_component(@codec.parse_json_document(data))
}

///|
/// Verify and read an externally produced single-layer Wasm artifact. The
/// config media type identifies the profile, including manifests that omit
/// artifactType. The caller supplies the trusted manifest descriptor.
pub fn inspect(
  source : @layout.MemoryLayout,
  descriptor : @model.Descriptor,
) -> WasmArtifact raise @model.MoonOciError {
  let limits = @artifacts.ArtifactLimits::default()
  @codec.validate_layout_marker(source.marker())
  if descriptor.media_type != @model.media_type_manifest {
    raise @model.InvalidOci("expected OCI image manifest for WebAssembly")
  }
  if descriptor.size > limits.max_manifest_bytes.to_int64() {
    raise @model.ResourceLimitExceeded(
      "WebAssembly artifact manifest exceeds 4 MiB",
    )
  }
  let manifest = @codec.decode_manifest(source.require_blob(descriptor))
  if manifest.schema_version != 2 ||
    manifest.media_type != @model.media_type_manifest ||
    manifest.config.media_type != config_media_type {
    raise @model.InvalidOci("unsupported WebAssembly artifact manifest")
  }
  guard manifest.layers is [layer] else {
    raise @model.Unsupported("WebAssembly v0 artifact requires one layer")
  }
  if layer.media_type != layer_media_type {
    raise @model.InvalidOci(
      "WebAssembly artifact layer must use application/wasm",
    )
  }
  if layer.size > limits.max_payload_bytes ||
    manifest.config.size > limits.max_config_bytes.to_int64() {
    raise @model.ResourceLimitExceeded(
      "WebAssembly artifact exceeds config or payload limit",
    )
  }
  let config = @codec.parse_json_document(source.require_blob(manifest.config))
  guard config is Object(fields) else {
    raise @model.InvalidOci("WebAssembly artifact config must be an object")
  }
  guard fields.get("layerDigests") is Some(Array([String(digest)])) &&
    digest == layer.digest.to_string() else {
    raise @model.DigestMismatch(
      "WebAssembly layerDigests does not match the manifest",
    )
  }
  let data = source.require_blob(layer)
  let binary = inspect_binary(data)
  let (os, component) = match (binary.kind, fields.get("component")) {
    (CoreModule, None) => ("wasip1", None)
    (Component, Some(value)) => ("wasip2", Some(read_component(value)))
    _ =>
      raise @model.InvalidOci(
        "WebAssembly component metadata disagrees with binary kind",
      )
  }
  if fields.get("architecture") != Some(Json::string("wasm")) ||
    fields.get("os") != Some(Json::string(os)) {
    raise @model.InvalidOci(
      "WebAssembly artifact config platform disagrees with binary kind",
    )
  }
  if descriptor.platform is Some(platform) &&
    (platform.architecture != "wasm" || platform.os != os) {
    raise @model.InvalidOci(
      "WebAssembly artifact advertised platform disagrees with config",
    )
  }
  {
    manifest: descriptor,
    binary,
    config: manifest.config,
    layer,
    data,
    component,
  }
}

///|
/// Describe a verified artifact without embedding its binary payload.
pub fn inspection_json(observation : WasmArtifact) -> String {
  let kind = match observation.binary.kind {
    CoreModule => "module"
    Component => "component"
  }
  let details : Json = {
    "schema": "moonoci.wasm-artifact.v1",
    "kind": Json::string(kind),
    "manifest": Json::string(observation.manifest.digest.to_string()),
    "config": Json::string(observation.config.digest.to_string()),
    "layer": Json::string(observation.layer.digest.to_string()),
    "bytes": Json::number(observation.data.length().to_double()),
    "sections": Json::number(observation.binary.sections.to_double()),
    "component": match observation.component {
      None => Json::null()
      Some(metadata) =>
        {
          "imports": Json::array(metadata.imports.map(Json::string)),
          "exports": Json::array(metadata.exports.map(Json::string)),
          "target": match metadata.target {
            None => Json::null()
            Some(target) => Json::string(target)
          },
        }
    },
  }
  details.stringify()
}
