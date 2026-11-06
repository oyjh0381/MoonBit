///|
/// List distinct reachable content, sorted by digest. Flat OCI image indexes
/// are supported; nested indexes/artifact manifests remain out of scope.
pub fn reachable_blobs(
  source : @layout.MemoryLayout,
) -> Array[@model.Descriptor] raise @model.MoonOciError {
  require_valid(source)
  let seen : Map[String, Bool] = Map([])
  let descriptors : Array[@model.Descriptor] = []
  for descriptor in @codec.decode_index(source.index()).manifests {
    let manifest = @codec.decode_manifest(source.require_blob(descriptor))
    let branch = [descriptor, manifest.config]
    branch.append(manifest.layers)
    for item in branch {
      let key = item.digest.to_string()
      if !seen.contains(key) {
        seen[key] = true
        descriptors.push(item)
      }
    }
  }
  descriptors.sort_by((a, b) => {
    a.digest.to_string().compare(b.digest.to_string())
  })
  descriptors
}

///|
/// Produce a verified copy containing only reachable blobs. Source is never
/// changed; deletion from a host filesystem remains the caller's responsibility.
pub fn compact(
  source : @layout.MemoryLayout,
) -> @layout.MemoryLayout raise @model.MoonOciError {
  let result = @layout.MemoryLayout::new()
  for descriptor in reachable_blobs(source) {
    ignore(
      result.put_blob(descriptor.media_type, source.require_blob(descriptor)),
    )
  }
  result.set_index(source.index())
  result
}

///|
pub(all) struct StorageInventory {
  stored_blobs : Int32
  reachable_blobs : Int32
  stored_bytes : Int64
  reachable_bytes : Int64
  reclaimable_bytes : Int64
}

///|
/// Account actual physical content independently of descriptor size assertions.
/// Ambiguous duplicate physical records are refused, even when unreferenced.
pub fn storage_inventory(
  source : @layout.MemoryLayout,
) -> StorageInventory raise @model.MoonOciError {
  let reachable = reachable_blobs(source)
  let seen : Map[String, Bool] = Map([])
  let mut stored_bytes = 0L
  for blob in source.blob_records() {
    let descriptor = blob.descriptor()
    let key = descriptor.digest.to_string()
    if seen.contains(key) {
      raise @model.InvalidOci("duplicate physical blob record")
    }
    seen[key] = true
    if descriptor.size != blob.data().length().to_int64() ||
      @digest.sha256(blob.data()) != descriptor.digest {
      raise @model.DigestMismatch("invalid physical blob record")
    }
    stored_bytes += blob.data().length().to_int64()
  }
  let mut reachable_bytes = 0L
  for descriptor in reachable {
    reachable_bytes += descriptor.size
  }
  {
    stored_blobs: source.blob_count(),
    reachable_blobs: reachable.length(),
    stored_bytes,
    reachable_bytes,
    reclaimable_bytes: stored_bytes - reachable_bytes,
  }
}
