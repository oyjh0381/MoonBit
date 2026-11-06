///|
/// Recover an arrival interrupted after the pending file was fully written but
/// before rename. Incomplete/corrupt files are retained and rejected, never
/// overwritten or automatically deleted. Returns committed/recovered/missing.
pub async fn recover_transfer_chunk(
  session : String,
  expected : @model.Digest,
  index : Int32,
) -> String {
  let plan = open_transfer_session(session, expected)
  let spec = plan.chunk(index)
  let destination = chunk_path(session, index)
  if @fs.exists(destination) {
    require_transfer_kind(destination, Regular)
    plan.verify_chunk(index, read_bounded_file(destination, spec.size))
    return "committed"
  }
  let pending = destination + ".pending"
  if !@fs.exists(pending) {
    return "missing"
  }
  require_transfer_kind(pending, Regular)
  plan.verify_chunk(index, read_bounded_file(pending, spec.size))
  @fs.rename(pending, destination, replace=false) catch {
    error => raise @model.IoFailure("cannot recover pending chunk: \{error}")
  }
  "recovered"
}

///|
/// Recover a complete staging output left by abrupt process termination.
/// Re-read bounded ranges and recheck both chunk and whole-content digests;
/// refuse existing destinations and leave failed partial files untouched.
pub async fn recover_transfer_output(
  session : String,
  expected : @model.Digest,
  destination : String,
) -> Unit {
  if destination.is_empty() {
    raise @model.InvalidArgument("transfer output path must not be empty")
  }
  let plan = open_transfer_session(session, expected)
  if @fs.exists(destination) {
    raise @model.IoFailure("transfer recovery destination already exists")
  }
  let staging = destination + ".moonoci-partial"
  {
    let file = open_chunk_source(staging)
    defer file.close()
    if file.size() != plan.size() {
      raise @model.SizeMismatch("partial output size does not match plan")
    }
    let verifier = @transfer.TransferVerifier::new(plan)
    for index in 0..<plan.chunk_count() {
      let spec = plan.chunk(index)
      verifier.accept(index, read_chunk_range(file, spec.size, spec.offset))
    }
    ignore(verifier.finish())
    if file.size() != plan.size() {
      raise @model.IoFailure("partial output size changed during recovery")
    }
  }
  @fs.rename(staging, destination, replace=false) catch {
    error =>
      raise @model.IoFailure("cannot publish recovered transfer: \{error}")
  }
}
