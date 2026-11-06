///|
pub(all) struct TransferBatch {
  chunks : Array[ChunkSpec]
  bytes : Int64
  pending_chunks : Int32
}

///|
/// Ascending missing-chunk prefix under byte/count budgets. The host must
/// establish the missing set by checking storage. This is not a completion proof.
pub fn PreparedTransfer::batch(
  self : PreparedTransfer,
  missing : Array[Int32],
  max_chunks~ : Int32 = 16,
  max_bytes~ : Int64 = 67108864L,
) -> TransferBatch raise @model.MoonOciError {
  if max_chunks < 1 ||
    max_chunks > 65536 ||
    max_bytes < 1L ||
    max_bytes > 8589934592L {
    raise @model.InvalidArgument(
      "batch budgets must be positive and within transfer hard limits",
    )
  }
  if missing.length() > self.chunk_count() {
    raise @model.InvalidArgument("too many missing chunk indexes")
  }
  if missing.is_empty() {
    return { chunks: [], bytes: 0L, pending_chunks: 0, }
  }
  let pending = FixedArray::make(self.chunk_count(), false)
  for index in missing {
    if index < 0 || index >= pending.length() || pending[index] {
      raise @model.InvalidArgument("invalid or duplicate missing chunk index")
    }
    pending[index] = true
  }
  let chunks = []
  let mut bytes = 0L
  for index in 0..<pending.length() {
    if !pending[index] {
      continue
    }
    let spec = self.chunk(index)
    if chunks.length() == max_chunks || spec.size.to_int64() > max_bytes - bytes {
      break
    }
    chunks.push(spec)
    bytes += spec.size.to_int64()
  }
  if !missing.is_empty() && chunks.is_empty() {
    raise @model.ResourceLimitExceeded(
      "batch byte budget cannot accommodate the next missing chunk",
    )
  }
  { chunks, bytes, pending_chunks: missing.length(), }
}

///|
pub fn batch_json(plan : PreparedTransfer, batch : TransferBatch) -> String {
  let chunks = batch.chunks
    .map(spec => {
      "{\"index\":" +
      spec.index.to_string() +
      ",\"offset\":\"" +
      spec.offset.to_string() +
      "\",\"size\":" +
      spec.size.to_string() +
      ",\"digest\":\"" +
      spec.digest.to_string() +
      "\"}"
    })
    .join(",")
  "{\"digest\":\"" +
  plan.digest().to_string() +
  "\",\"bytes\":\"" +
  batch.bytes.to_string() +
  "\",\"pending_chunks\":" +
  batch.pending_chunks.to_string() +
  ",\"chunks\":[" +
  chunks +
  "]}"
}
