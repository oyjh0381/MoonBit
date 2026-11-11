///|
/// One immutable content-addressed object stored in an in-memory layout.
#derive(Debug, Eq)
pub struct BlobRecord {
  priv descriptor : @model.Descriptor
  priv data : Bytes
}

///|
/// Portable in-memory representation of the files in an OCI Image Layout.
#derive(Debug, Eq)
pub struct MemoryLayout {
  priv marker : Bytes
  priv mut index : Bytes
  priv blobs : Array[BlobRecord]
  priv lookup : Map[String, Int32]
}

///|
/// Construct an empty OCI Image Layout with the v1 marker.
pub fn MemoryLayout::new() -> MemoryLayout {
  {
    marker: b"{\"imageLayoutVersion\":\"1.0.0\"}",
    index: b"",
    blobs: [],
    lookup: Map([]),
  }
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
  let lookup : Map[String, Int32] = Map([])
  for pair in blobs {
    let (descriptor, data) = pair
    let key = descriptor.digest.to_string()
    // Keep the first-record lookup behavior for untrusted duplicate input.
    // The complete record sequence is retained for strict inventory rejection.
    if !lookup.contains(key) {
      lookup[key] = records.length()
    }
    records.push({ descriptor, data, })
  }
  { marker, index, blobs: records, lookup, }
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
pub fn MemoryLayout::blob_count(self : MemoryLayout) -> Int32 {
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
  annotations~ : Array[@model.KeyValue] = [],
  platform? : @model.Platform,
) -> @model.Descriptor raise @model.MoonOciError {
  let descriptor : @model.Descriptor = {
    media_type,
    digest: @digest.sha256(data),
    size: data.length().to_int64(),
    annotations,
    platform,
  }
  let key = descriptor.digest.to_string()
  match self.lookup.get(key) {
    Some(index) => {
      let blob = self.blobs[index]
      if blob.data != data {
        raise @model.DigestMismatch(
          "different content produced an existing digest",
        )
      }
      return descriptor
    }
    None => ()
  }
  self.lookup[key] = self.blobs.length()
  self.blobs.push({ descriptor, data, })
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
  match self.lookup.get(digest.to_string()) {
    Some(index) => Some(self.blobs[index].data)
    None => None
  }
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

///|
pub extend BlobRecord with @debug.Debug::{to_repr}

///|
pub extend BlobRecord with Eq::{not_equal, equal}

///|
pub extend MemoryLayout with @debug.Debug::{to_repr}

///|
pub extend MemoryLayout with Eq::{not_equal, equal}
