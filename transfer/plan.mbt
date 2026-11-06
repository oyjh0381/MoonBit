///|
/// Host-adjustable logical quotas. These do not bound the host's total heap.
pub(all) struct ChunkLimits {
  max_chunks : Int32
  max_chunk_bytes : Int32
  max_blob_bytes : Int64
}

///|
pub fn ChunkLimits::default() -> ChunkLimits {
  { max_chunks: 65536, max_chunk_bytes: 16777216, max_blob_bytes: 8589934592L, }
}

///|
pub fn ChunkLimits::validate(
  self : ChunkLimits,
) -> Unit raise @model.MoonOciError {
  if self.max_chunks < 1 ||
    self.max_chunks > 65536 ||
    self.max_chunk_bytes < 1 ||
    self.max_chunk_bytes > 16777216 ||
    self.max_blob_bytes < 0L ||
    self.max_blob_bytes > 8589934592L {
    raise @model.InvalidArgument(
      "invalid chunk limits: at most 65536 chunks, 16 MiB/chunk, 8 GiB/blob",
    )
  }
}

///|
/// Untrusted transport metadata. Offsets and sizes are derived, never supplied.
pub(all) struct ChunkPlan {
  digest : @model.Digest
  size : Int64
  chunk_bytes : Int32
  chunks : Array[@model.Digest]
}

///|
/// Validated snapshot; later mutation of a caller's digest array cannot alter it.
pub struct PreparedTransfer {
  digest : @model.Digest
  size : Int64
  chunk_bytes : Int32
  chunks : Array[@model.Digest]
}

///|
pub(all) struct ChunkSpec {
  index : Int32
  offset : Int64
  size : Int32
  digest : @model.Digest
}

///|
/// Bind metadata to a caller-owned whole-content pin. Per-chunk hashes alone
/// are not an authenticity proof; the assembled whole digest must still match.
pub fn prepare(
  plan : ChunkPlan,
  expected : @model.Digest,
  limits~ : ChunkLimits = ChunkLimits::default(),
) -> PreparedTransfer raise @model.MoonOciError {
  limits.validate()
  ignore(@model.Digest::parse(expected.to_string()))
  ignore(@model.Digest::parse(plan.digest.to_string()))
  if plan.digest != expected {
    raise @model.DigestMismatch("unexpected whole-content pin")
  }
  if plan.size < 0L ||
    plan.size > limits.max_blob_bytes ||
    plan.chunk_bytes < 1 ||
    plan.chunk_bytes > limits.max_chunk_bytes ||
    plan.chunks.length() > limits.max_chunks {
    raise @model.ResourceLimitExceeded("chunk plan exceeds content quotas")
  }
  let count = if plan.size == 0L {
    0L
  } else {
    (plan.size - 1L) / plan.chunk_bytes.to_int64() + 1L
  }
  if count != plan.chunks.length().to_int64() {
    raise @model.SizeMismatch(
      "chunk count does not cover the whole content exactly",
    )
  }
  for digest in plan.chunks {
    ignore(@model.Digest::parse(digest.to_string()))
  }
  if plan.size == 0L && plan.digest != @digest.sha256(b"") {
    raise @model.DigestMismatch(
      "empty content must have the SHA-256 empty digest",
    )
  }
  {
    digest: plan.digest,
    size: plan.size,
    chunk_bytes: plan.chunk_bytes,
    chunks: plan.chunks.copy(),
  }
}

///|
pub fn PreparedTransfer::digest(self : PreparedTransfer) -> @model.Digest {
  self.digest
}

///|
pub fn PreparedTransfer::size(self : PreparedTransfer) -> Int64 {
  self.size
}

///|
pub fn PreparedTransfer::chunk_bytes(self : PreparedTransfer) -> Int32 {
  self.chunk_bytes
}

///|
pub fn PreparedTransfer::chunk_count(self : PreparedTransfer) -> Int32 {
  self.chunks.length()
}

///|
pub fn PreparedTransfer::chunk(
  self : PreparedTransfer,
  index : Int32,
) -> ChunkSpec raise @model.MoonOciError {
  if index < 0 || index >= self.chunks.length() {
    raise @model.InvalidArgument("chunk index is outside the prepared transfer")
  }
  let offset = index.to_int64() * self.chunk_bytes.to_int64()
  let remaining = self.size - offset
  {
    index,
    offset,
    size: if remaining < self.chunk_bytes.to_int64() {
      remaining.to_int()
    } else {
      self.chunk_bytes
    },
    digest: self.chunks[index],
  }
}

///|
/// Constant-time metadata lookup, linear hashing in this chunk's byte length.
pub fn PreparedTransfer::verify_chunk(
  self : PreparedTransfer,
  index : Int32,
  bytes : Bytes,
) -> Unit raise @model.MoonOciError {
  let spec = self.chunk(index)
  if bytes.length() != spec.size {
    raise @model.SizeMismatch("chunk byte length mismatch")
  }
  if @digest.sha256(bytes) != spec.digest {
    raise @model.DigestMismatch("chunk SHA-256 mismatch")
  }
}

///|
/// In-memory producer convenience. Native producers can hash files incrementally.
pub fn plan_bytes(
  bytes : Bytes,
  chunk_bytes~ : Int32 = 1048576,
  limits~ : ChunkLimits = ChunkLimits::default(),
) -> PreparedTransfer raise @model.MoonOciError {
  limits.validate()
  if chunk_bytes < 1 ||
    chunk_bytes > limits.max_chunk_bytes ||
    bytes.length().to_int64() > limits.max_blob_bytes {
    raise @model.ResourceLimitExceeded("source exceeds chunk plan limits")
  }
  let count = if bytes.is_empty() {
    0
  } else {
    (bytes.length() - 1) / chunk_bytes + 1
  }
  if count > limits.max_chunks {
    raise @model.ResourceLimitExceeded("source needs too many chunks")
  }
  let chunks = []
  let mut offset = 0
  while offset < bytes.length() {
    let length = if bytes.length() - offset < chunk_bytes {
      bytes.length() - offset
    } else {
      chunk_bytes
    }
    chunks.push(@digest.sha256(bytes[offset:offset + length].to_owned()))
    offset += length
  }
  let digest = @digest.sha256(bytes)
  prepare(
    { digest, size: bytes.length().to_int64(), chunk_bytes, chunks, },
    digest,
    limits~,
  )
}
