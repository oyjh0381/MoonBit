///|
/// Package a local Wasm file into a new OCI layout with bounded input reads.
pub async fn pack_wasm_file(
  input : String,
  reference : String,
  destination : String,
  component_file? : String,
) -> @model.Descriptor {
  if @fs.exists(destination) {
    raise @model.IoFailure("WebAssembly layout destination already exists")
  }
  let limits = @artifacts.ArtifactLimits::default()
  let component = match component_file {
    Some(path) =>
      Some(
        @wasmartifact.decode_component_metadata(
          read_bounded_file(path, limits.max_config_bytes),
        ),
      )
    None => None
  }
  let data = read_bounded_file(input, limits.max_payload_bytes.to_int())
  let bundle = @wasmartifact.pack(data, reference, component?)
  write_layout(destination, bundle.layout)
  bundle.descriptor
}
