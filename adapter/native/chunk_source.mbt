///|
async fn open_chunk_source(path : String) -> @fs.File {
  if @fs.kind(path, follow_symlink=false) != Regular {
    raise @model.IoFailure("transfer source must be a regular non-symlink file")
  }
  let file = @fs.open(path, mode=ReadOnly) catch {
    error => raise @model.IoFailure("cannot open transfer source: \{error}")
  }
  if file.kind() != Regular {
    file.close()
    raise @model.IoFailure("transfer source changed file kind")
  }
  file
}

///|
async fn read_chunk_range(
  file : @fs.File,
  size : Int32,
  offset : Int64,
) -> Bytes {
  file.read_exactly_at(size, position=offset) catch {
    error =>
      raise @model.IoFailure("cannot read complete transfer chunk: \{error}")
  }
}

///|
async fn load_chunk_plan(
  path : String,
  expected : @model.Digest,
) -> @transfer.PreparedTransfer {
  if @fs.kind(path, follow_symlink=false) != Regular {
    raise @model.IoFailure("transfer plan must be a regular non-symlink file")
  }
  @transfer.decode_plan(
    read_bounded_file(path, @transfer.max_plan_bytes),
    expected,
  )
}

///|
/// Two incremental hashes per chunk, O(chunk size + digest count) retained data.
/// No whole-file allocation. The caller must keep input files quiescent.
pub async fn create_chunk_plan(
  source : String,
  chunk_bytes : Int32,
  destination : String,
  limits~ : @transfer.ChunkLimits = @transfer.ChunkLimits::default(),
) -> @transfer.PreparedTransfer {
  limits.validate()
  if chunk_bytes < 1 || chunk_bytes > limits.max_chunk_bytes {
    raise @model.InvalidArgument("chunk size is outside the configured range")
  }
  if @fs.exists(destination) {
    raise @model.IoFailure("chunk plan destination already exists")
  }
  let file = open_chunk_source(source)
  defer file.close()
  let size = file.size()
  if size < 0L || size > limits.max_blob_bytes {
    raise @model.ResourceLimitExceeded("transfer source byte quota exceeded")
  }
  let count = if size == 0L {
    0L
  } else {
    (size - 1L) / chunk_bytes.to_int64() + 1L
  }
  if count > limits.max_chunks.to_int64() {
    raise @model.ResourceLimitExceeded("transfer source needs too many chunks")
  }
  let state = @digest.Sha256::new()
  let chunks = []
  let mut offset = 0L
  while offset < size {
    let remaining = size - offset
    let length = if remaining < chunk_bytes.to_int64() {
      remaining.to_int()
    } else {
      chunk_bytes
    }
    let bytes = read_chunk_range(file, length, offset)
    state.update(bytes)
    chunks.push(@digest.sha256(bytes))
    offset += length.to_int64()
  }
  if file.size() != size {
    raise @model.IoFailure("transfer source size changed while planning")
  }
  let digest = state.finish()
  let plan = @transfer.prepare(
    { digest, size, chunk_bytes, chunks, },
    digest,
    limits~,
  )
  @fs.write_file(
    destination,
    @transfer.encode_plan(plan),
    create_mode=CreateNew,
  ) catch {
    error => raise @model.IoFailure("cannot create chunk plan: \{error}")
  }
  plan
}

///|
/// Export one independently verified range; reusable by offline or HTTP hosts.
pub async fn export_transfer_chunk(
  source : String,
  plan_path : String,
  expected : @model.Digest,
  index : Int32,
  destination : String,
) -> Unit {
  let plan = load_chunk_plan(plan_path, expected)
  let spec = plan.chunk(index)
  if @fs.exists(destination) {
    raise @model.IoFailure("chunk export destination already exists")
  }
  let file = open_chunk_source(source)
  defer file.close()
  if file.size() != plan.size() {
    raise @model.SizeMismatch("chunk source size differs from plan")
  }
  let bytes = read_chunk_range(file, spec.size, spec.offset)
  plan.verify_chunk(index, bytes)
  if file.size() != plan.size() {
    raise @model.IoFailure("chunk source size changed during export")
  }
  @fs.write_file(destination, bytes, create_mode=CreateNew) catch {
    error => raise @model.IoFailure("cannot export transfer chunk: \{error}")
  }
}
