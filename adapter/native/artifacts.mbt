///|
pub async fn attach_artifact_file(
  source : String,
  subject : @model.Digest,
  artifact_type : String,
  payload_media_type : String,
  payload : String,
  reference : String,
  destination : String,
) -> @model.Descriptor {
  let store = load_layout(source)
  let descriptor = @artifacts.resolve_subject(store, subject)
  let bytes = read_bounded_file(payload, 67108864)
  let bundle = @artifacts.attach(
    store,
    descriptor,
    artifact_type,
    [{ media_type: payload_media_type, data: bytes, annotations: [], }],
    reference~,
  )
  write_layout(destination, bundle.layout)
  bundle.descriptor
}

///|
pub async fn export_artifact_payload(
  source : String,
  artifact : @model.Digest,
  index : Int32,
  destination : String,
) -> Unit {
  if @fs.exists(destination) {
    raise @model.IoFailure("artifact payload destination already exists")
  }
  let store = load_layout(source)
  let descriptor = @artifacts.resolve_subject(store, artifact)
  let bytes = @artifacts.payload_bytes(store, descriptor, index)
  @fs.write_file(destination, bytes, create_mode=CreateNew) catch {
    error => raise @model.IoFailure("cannot write artifact payload: \{error}")
  }
}
