///|
fn require_valid(
  source : @layout.MemoryLayout,
) -> Unit raise @model.MoonOciError {
  if !@builder.verify_memory(source).is_valid() {
    raise @model.InvalidOci("distribution requires a verified descriptor graph")
  }
  for descriptor in @codec.decode_index(source.index()).manifests {
    if descriptor.platform is Some(platform) {
      let manifest = @codec.decode_manifest(source.require_blob(descriptor))
      let config = @codec.decode_config(source.require_blob(manifest.config))
      if config.platform != platform {
        raise @model.InvalidOci(
          "descriptor platform disagrees with image configuration",
        )
      }
    }
  }
}

///|
/// Combine verified single/multi-platform layouts; duplicate platform identities
/// are refused rather than silently selecting one. Source objects are untouched.
pub fn merge(
  sources : Array[@layout.MemoryLayout],
) -> @layout.MemoryLayout raise @model.MoonOciError {
  if sources.is_empty() {
    raise @model.InvalidArgument("at least one layout is required")
  }
  let result = @layout.MemoryLayout::new()
  let manifests : Array[@model.Descriptor] = []
  let platforms : Array[@model.Platform] = []
  for source in sources {
    require_valid(source)
    let index = @codec.decode_index(source.index())
    for descriptor in index.manifests {
      let platform = match descriptor.platform {
        Some(p) => p
        None =>
          raise @model.InvalidOci("platform metadata required for distribution")
      }
      if platforms.contains(platform) {
        raise @model.InvalidArgument("duplicate distribution platform")
      }
      platforms.push(platform)
      manifests.push(descriptor)
    }
    for blob in source.blob_records() {
      ignore(result.put_blob(blob.descriptor().media_type, blob.data()))
    }
  }
  if manifests.is_empty() {
    raise @model.InvalidArgument("distribution has no images")
  }
  // Stable ordering makes composition independent of caller source order.
  manifests.sort_by((a, b) => a.digest.to_string().compare(b.digest.to_string()))
  result.set_index(
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests,
      annotations: [],
    }),
  )
  result
}

///|
/// Exact platform selection includes variant and os.version. No host guessing.
pub fn select(
  source : @layout.MemoryLayout,
  platform : @model.Platform,
) -> @model.Descriptor raise @model.MoonOciError {
  require_valid(source)
  let matches = @codec.decode_index(source.index()).manifests.filter(d => {
    d.platform == Some(platform)
  })
  if matches.length() != 1 {
    raise @model.InvalidArgument("platform must identify exactly one manifest")
  }
  matches[0]
}

///|
/// Copy only a chosen manifest and its config/layers into a standalone layout.
pub fn slice(
  source : @layout.MemoryLayout,
  platform : @model.Platform,
) -> @layout.MemoryLayout raise @model.MoonOciError {
  let descriptor = select(source, platform)
  let manifest = @codec.decode_manifest(source.require_blob(descriptor))
  let result = @layout.MemoryLayout::new()
  let needed = [descriptor, manifest.config]
  needed.append(manifest.layers)
  for item in needed {
    ignore(result.put_blob(item.media_type, source.require_blob(item)))
  }
  result.set_index(
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests: [descriptor],
      annotations: [],
    }),
  )
  result
}

///|
/// Plan transfer of target blobs absent from the verified base content store.
/// Metadata/index must still be delivered; this returns a plan, not a partial OCI layout.
pub fn missing_blobs(
  base : @layout.MemoryLayout,
  target : @layout.MemoryLayout,
) -> Array[@model.Descriptor] raise @model.MoonOciError {
  require_valid(base)
  require_valid(target)
  let missing : Array[@model.Descriptor] = []
  for blob in target.blob_records() {
    if base.get_blob(blob.descriptor().digest) is None {
      missing.push(blob.descriptor())
    }
  }
  missing.sort_by((a, b) => a.digest.to_string().compare(b.digest.to_string()))
  missing
}

///|
/// Validate a trusted external index digest before graph traversal. This is an
/// integrity pin; authenticating the external digest belongs to the caller.
pub fn verify_pin(
  source : @layout.MemoryLayout,
  expected : @model.Digest,
) -> Unit raise @model.MoonOciError {
  if @digest.sha256(source.index()) != expected {
    raise @model.DigestMismatch("index integrity pin mismatch")
  }
  require_valid(source)
}
