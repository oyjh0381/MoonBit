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

///|
/// Resolve a reference under a caller-supplied index pin and validate its Wasm
/// content before returning the inspection.
pub async fn inspect_wasm_layout(
  source : String,
  expected_index : @model.Digest,
  reference : String,
) -> @wasmartifact.WasmArtifact {
  let layout = load_bounded_layout(source)
  let catalog = @lifecycle.catalog(layout, expected_index)
  let descriptor = catalog.resolve_reference(reference)
  @wasmartifact.inspect(layout, descriptor)
}

///|
/// Extract only the verified payload to a new caller-selected file.
pub async fn export_wasm_file(
  source : String,
  expected_index : @model.Digest,
  reference : String,
  destination : String,
) -> @wasmartifact.WasmArtifact {
  if destination.is_empty() {
    raise @model.InvalidArgument("WebAssembly destination must not be empty")
  }
  if @fs.exists(destination) {
    raise @model.IoFailure("WebAssembly destination already exists")
  }
  let observation = inspect_wasm_layout(source, expected_index, reference)
  let staging = destination + ".moonoci-partial"
  let file = @fs.open(staging, mode=WriteOnly, create_mode=CreateNew) catch {
    error =>
      raise @model.IoFailure("cannot create WebAssembly staging file: \{error}")
  }
  try {
    {
      defer file.close()
      file.write_at(observation.data, position=0L)
      file.sync()
    }
    @fs.rename(staging, destination, replace=false)
  } catch {
    error => {
      @fs.remove(staging) catch {
        _ => ()
      }
      raise @model.IoFailure("cannot export WebAssembly payload: \{error}")
    }
  }
  observation
}
