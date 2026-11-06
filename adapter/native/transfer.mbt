///|
/// Write a new deterministic transfer archive; refuse an existing output.
pub async fn create_delta_file(
  base : String,
  target : String,
  destination : String,
) -> Unit {
  if @fs.exists(destination) {
    raise @model.IoFailure("transfer destination already exists")
  }
  let envelope = @distribution.create_delta(
    load_layout(base),
    load_layout(target),
  )
  let bytes = @distribution.encode_delta(envelope)
  @fs.write_file(destination, bytes, create_mode=CreateNew) catch {
    error => raise @model.IoFailure("cannot write transfer archive: \{error}")
  }
}

///|
/// Verify a transfer completely before invoking staged layout materialization.
pub async fn apply_delta_file(
  base : String,
  archive : String,
  expected : @model.Digest,
  destination : String,
) -> Unit {
  let wire = read_bounded_file(archive, 570425344)
  let envelope = @distribution.decode_delta(wire)
  let hydrated = @distribution.hydrate(load_layout(base), envelope, expected)
  write_layout(destination, hydrated)
}
