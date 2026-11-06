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
  let wire = read_transfer_file(archive)
  let envelope = @distribution.decode_delta(wire)
  let hydrated = @distribution.hydrate(load_layout(base), envelope, expected)
  write_layout(destination, hydrated)
}

///|
// Bounds apply before allocation and reads. Files must be trusted/quiescent;
// size-change detection cannot detect concurrent equal-size rewrites.
async fn read_transfer_file(path : String) -> Bytes {
  let file = @fs.open(path, mode=@fs.ReadOnly)
  defer file.close()
  let size = file.size()
  if size < 0L || size > 570425344L {
    raise @model.ResourceLimitExceeded("transfer file exceeds 544 MiB")
  }
  let buffer = FixedArray::make(size.to_int() + 1, b'\x00')
  let mut received = 0
  while received < buffer.length() {
    let count = file.read_at(
      buffer,
      position=received.to_int64(),
      offset=received,
      len=buffer.length() - received,
    )
    if count == 0 {
      break
    }
    received += count
  }
  if received.to_int64() != size {
    raise @model.IoFailure("transfer file changed during reading")
  }
  Bytes::from_array(buffer)[0:received].to_owned()
}
