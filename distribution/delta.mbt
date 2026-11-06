///|
pub(all) struct DeltaBlob {
  descriptor : @model.Descriptor
  data : Bytes
}

///|
/// A MoonOCI transfer envelope, not an independently loadable OCI image.
pub(all) struct DeltaEnvelope {
  base_index : @model.Digest
  target_index : @model.Digest
  marker : Bytes
  index : Bytes
  blobs : Array[DeltaBlob]
}

///|
pub(all) struct TransferLimits {
  max_blobs : Int32
  max_blob_bytes : Int64
  max_total_bytes : Int64
  max_index_bytes : Int32
}

///|
pub fn TransferLimits::default() -> TransferLimits {
  {
    max_blobs: 4096,
    max_blob_bytes: 268435456L,
    max_total_bytes: 536870912L,
    max_index_bytes: 16777216,
  }
}

///|
fn check_envelope(
  envelope : DeltaEnvelope,
  limits : TransferLimits,
) -> Unit raise @model.MoonOciError {
  if limits.max_blobs < 1 ||
    limits.max_blobs > 100000 ||
    limits.max_blob_bytes < 1L ||
    limits.max_total_bytes < 1L ||
    limits.max_index_bytes < 1 {
    raise @model.InvalidArgument(
      "transfer limits must be positive; max_blobs <= 100000",
    )
  }
  if envelope.index.length() > limits.max_index_bytes ||
    envelope.marker.length() > 1024 ||
    envelope.blobs.length() > limits.max_blobs {
    raise @model.ResourceLimitExceeded(
      "transfer envelope metadata quota exceeded",
    )
  }
  let mut total = envelope.index.length().to_int64() +
    envelope.marker.length().to_int64()
  let seen : Map[String, Bool] = Map([])
  for blob in envelope.blobs {
    let size = blob.data.length().to_int64()
    total += size
    if size > limits.max_blob_bytes || total > limits.max_total_bytes {
      raise @model.ResourceLimitExceeded("transfer content quota exceeded")
    }
    let key = blob.descriptor.digest.to_string()
    if seen.contains(key) {
      raise @model.InvalidOci("duplicate transfer blob")
    }
    seen[key] = true
    if size != blob.descriptor.size {
      raise @model.SizeMismatch("transfer blob size mismatch")
    }
    if @digest.sha256(blob.data) != blob.descriptor.digest {
      raise @model.DigestMismatch("transfer blob digest mismatch")
    }
  }
  if total > limits.max_total_bytes {
    raise @model.ResourceLimitExceeded("transfer metadata byte quota exceeded")
  }
  if @digest.sha256(envelope.index) != envelope.target_index {
    raise @model.DigestMismatch("transfer target index mismatch")
  }
}

///|
/// Create a minimal envelope from verified source content, under explicit quotas.
pub fn create_delta(
  base : @layout.MemoryLayout,
  target : @layout.MemoryLayout,
  limits~ : TransferLimits = TransferLimits::default(),
) -> DeltaEnvelope raise @model.MoonOciError {
  ignore(storage_inventory(base))
  let descriptors = missing_blobs(base, target)
  let envelope : DeltaEnvelope = {
    base_index: @digest.sha256(base.index()),
    target_index: @digest.sha256(target.index()),
    marker: target.marker(),
    index: target.index(),
    blobs: descriptors.map(d => { descriptor: d, data: target.require_blob(d), }),
  }
  check_envelope(envelope, limits)
  envelope
}

///|
/// Validate before returning a fresh, compact, complete OCI layout. On failure
/// the base and envelope are untouched. expected_target must come from the host's
/// trusted release metadata, not merely be copied from an untrusted envelope.
pub fn hydrate(
  base : @layout.MemoryLayout,
  envelope : DeltaEnvelope,
  expected_target : @model.Digest,
  limits~ : TransferLimits = TransferLimits::default(),
) -> @layout.MemoryLayout raise @model.MoonOciError {
  if envelope.target_index != expected_target {
    raise @model.DigestMismatch("unexpected transfer target")
  }
  if @digest.sha256(base.index()) != envelope.base_index {
    raise @model.DigestMismatch("transfer base index mismatch")
  }
  check_envelope(envelope, limits)
  ignore(storage_inventory(base))
  let records = base.blob_records().map(b => (b.descriptor(), b.data()))
  for blob in envelope.blobs {
    if base.get_blob(blob.descriptor.digest) is Some(_) {
      raise @model.InvalidOci("transfer redundantly includes base content")
    }
    records.push((blob.descriptor, blob.data))
  }
  let candidate = @layout.MemoryLayout::from_untrusted_parts(
    envelope.marker,
    envelope.index,
    records,
  )
  let result = compact(candidate)
  // All transported content must actually belong to the declared target graph.
  let reachable = reachable_blobs(result)
  for blob in envelope.blobs {
    if !reachable.any(d => d.digest == blob.descriptor.digest) {
      raise @model.InvalidOci("unreferenced transfer content")
    }
  }
  result
}
