///|
pub(all) struct WasmArtifact {
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
  { binary, config: manifest.config, layer, data, component, }
}
