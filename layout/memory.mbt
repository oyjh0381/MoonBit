///|
/// One immutable content-addressed object stored in an in-memory layout.
pub struct BlobRecord {
  descriptor : @model.Descriptor
  data : Bytes
} derive(Debug, Eq)

///|
/// Portable in-memory representation of the files in an OCI Image Layout.
pub struct MemoryLayout {
  marker : Bytes
  mut index : Bytes
  blobs : Array[BlobRecord]
} derive(Debug, Eq)

///|
/// Construct an empty OCI Image Layout with the v1 marker.
pub fn MemoryLayout::new() -> MemoryLayout {
  { marker: b"{\"imageLayoutVersion\":\"1.0.0\"}", index: b"", blobs: [] }
}

///|
/// Construct an immutable layout from untrusted filesystem parts. Descriptor
/// validation remains the verifier's responsibility.
pub fn MemoryLayout::from_untrusted_parts(
  marker : Bytes,
  index : Bytes,
  blobs : Array[(@model.Descriptor, Bytes)],
) -> MemoryLayout {
  let records : Array[BlobRecord] = []
  for pair in blobs {
    let (descriptor, data) = pair
    records.push({ descriptor, data })
  }
  { marker, index, blobs: records }
}

///|
pub fn MemoryLayout::marker(self : MemoryLayout) -> Bytes {
  self.marker
}

///|
pub fn MemoryLayout::index(self : MemoryLayout) -> Bytes {
  self.index
}

///|
pub fn MemoryLayout::blob_records(self : MemoryLayout) -> Array[BlobRecord] {
  self.blobs.copy()
}

///|
pub fn MemoryLayout::blob_count(self : MemoryLayout) -> Int {
  self.blobs.length()
}

///|
pub fn BlobRecord::descriptor(self : BlobRecord) -> @model.Descriptor {
  self.descriptor
}

///|
pub fn BlobRecord::data(self : BlobRecord) -> Bytes {
  self.data
}

///|
/// Insert content and return its Descriptor. Identical content is deduplicated.
pub fn MemoryLayout::put_blob(
  self : MemoryLayout,
  media_type : String,
  data : Bytes,
  annotations? : Array[@model.KeyValue] = [],
  platform? : @model.Platform,
) -> @model.Descriptor raise @model.MoonOciError {
  let descriptor : @model.Descriptor = {
    media_type,
    digest: @digest.sha256(data),
    size: data.length().to_int64(),
    annotations,
    platform,
  }
  for blob in self.blobs {
    if blob.descriptor.digest == descriptor.digest {
      if blob.data != data {
        raise @model.DigestMismatch(
          "different content produced an existing digest",
        )
      }
      return descriptor
    }
  }
  self.blobs.push({ descriptor, data })
  descriptor
}

///|
/// Set the root `index.json` document after its referenced Blobs are stored.
pub fn MemoryLayout::set_index(self : MemoryLayout, index : Bytes) -> Unit {
  self.index = index
}

///|
/// Find immutable Blob bytes by Digest.
pub fn MemoryLayout::get_blob(
  self : MemoryLayout,
  digest : @model.Digest,
) -> Bytes? {
  for blob in self.blobs {
    if blob.descriptor.digest == digest {
      return Some(blob.data)
    }
  }
  None
}

///|
/// Validate one Descriptor against content present in this layout.
pub fn MemoryLayout::require_blob(
  self : MemoryLayout,
  descriptor : @model.Descriptor,
) -> Bytes raise @model.MoonOciError {
  let data = match self.get_blob(descriptor.digest) {
    Some(data) => data
    None =>
      raise @model.InvalidOci("missing blob: " + descriptor.digest.to_string())
  }
  if data.length().to_int64() != descriptor.size {
    raise @model.SizeMismatch(
      "descriptor size mismatch for " + descriptor.digest.to_string(),
    )
  }
  if @digest.sha256(data) != descriptor.digest {
    raise @model.DigestMismatch(
      "blob digest mismatch for " + descriptor.digest.to_string(),
    )
  }
  data
}

///|
/// Total stored Blob bytes, excluding the marker and root index.
pub fn MemoryLayout::blob_bytes(self : MemoryLayout) -> Int64 {
  let mut total = 0L
  for blob in self.blobs {
    total += blob.data.length().to_int64()
  }
  total
}
