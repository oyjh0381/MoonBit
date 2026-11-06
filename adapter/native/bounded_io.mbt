///|
/// Shared explicit-file reader for bounded transfer and artifact adapters.
async fn read_bounded_file(path : String, limit : Int32) -> Bytes {
  if limit < 1 || limit == 2147483647 {
    raise @model.InvalidArgument("invalid file read limit")
  }
  let file = @fs.open(path, mode=@fs.ReadOnly) catch {
    error => raise @model.IoFailure("cannot open input: \{error}")
  }
  defer file.close()
  let size = file.size() catch {
    error => raise @model.IoFailure("cannot stat input: \{error}")
  }
  if size < 0L || size > limit.to_int64() {
    raise @model.ResourceLimitExceeded("input file byte quota exceeded")
  }
  let buffer = FixedArray::make(size.to_int() + 1, b'\x00')
  let mut received = 0
  while received < buffer.length() {
    let count = file.read_at(
      buffer,
      position=received.to_int64(),
      offset=received,
      len=buffer.length() - received,
    ) catch {
      error => raise @model.IoFailure("cannot read input: \{error}")
    }
    if count == 0 {
      break
    }
    received += count
  }
  if received.to_int64() != size {
    raise @model.IoFailure("input file changed during reading")
  }
  Bytes::from_array(buffer)[0:received].to_owned()
}
