///|
pub(all) struct WalkLimits {
  max_depth : Int32
  max_visits : Int32
  max_metadata_bytes : Int64
}

///|
pub fn WalkLimits::default() -> WalkLimits {
  { max_depth: 16, max_visits: 4096, max_metadata_bytes: 134217728L, }
}

///|
pub(all) struct ImageLeaf {
  descriptor : @model.Descriptor
  platform : @model.Platform
  index_path : Array[Int32]
  ancestor_indexes : Array[@model.Digest]
}

///|
pub(all) struct SkippedDescriptor {
  descriptor : @model.Descriptor
  index_path : Array[Int32]
  reason : String
}

///|
pub(all) struct IndexWalk {
  indexes : Array[IndexNode]
  images : Array[ImageLeaf]
  skipped : Array[SkippedDescriptor]
  visits : Int32
  metadata_bytes : Int64
  complete : Bool
}

///|
pub(all) struct IndexNode {
  descriptor : @model.Descriptor
  index_path : Array[Int32]
}

///|
priv struct WalkState {
  indexes : Array[IndexNode]
  limits : WalkLimits
  source : @layout.MemoryLayout
  images : Array[ImageLeaf]
  skipped : Array[SkippedDescriptor]
  checked : Map[String, Bytes]
  mut visits : Int32
  mut bytes : Int64
}

///|
/// Bounded metadata traversal in source order. Unknown media are observations,
/// not structural errors; their content is not fetched or treated as verified.
pub fn walk_indexes(
  source : @layout.MemoryLayout,
  limits~ : WalkLimits = WalkLimits::default(),
) -> IndexWalk raise @model.MoonOciError {
  if limits.max_depth < 1 ||
    limits.max_depth > 128 ||
    limits.max_visits < 1 ||
    limits.max_visits > 100000 ||
    limits.max_metadata_bytes < 1L {
    raise @model.InvalidArgument("invalid index traversal limits")
  }
  if source.index().length().to_int64() > limits.max_metadata_bytes {
    raise @model.ResourceLimitExceeded("root index byte quota exceeded")
  }
  @codec.validate_layout_marker(source.marker())
  let root = @codec.decode_index(source.index())
  require_index(root)
  let state : WalkState = {
    indexes: [],
    limits,
    source,
    images: [],
    skipped: [],
    checked: Map([]),
    visits: 0,
    bytes: source.index().length().to_int64(),
  }
  for i, descriptor in root.manifests {
    walk_descriptor(state, descriptor, [i], [], [])
  }
  {
    indexes: state.indexes,
    images: state.images,
    skipped: state.skipped,
    visits: state.visits,
    metadata_bytes: state.bytes,
    complete: state.skipped.is_empty(),
  }
}

///|
fn require_index(index : @model.ImageIndex) -> Unit raise @model.MoonOciError {
  if index.schema_version != 2 || index.media_type != @model.media_type_index {
    raise @model.InvalidOci("invalid nested index schema or media type")
  }
}

///|
fn metadata(
  state : WalkState,
  descriptor : @model.Descriptor,
) -> Bytes raise @model.MoonOciError {
  match state.checked.get(descriptor.digest.to_string()) {
    Some(data) => {
      if data.length().to_int64() != descriptor.size {
        raise @model.SizeMismatch("inconsistent repeated metadata descriptor")
      }
      data
    }
    None => {
      if descriptor.size < 0L ||
        descriptor.size > state.limits.max_metadata_bytes - state.bytes {
        raise @model.ResourceLimitExceeded("index metadata byte quota exceeded")
      }
      let data = state.source.require_blob(descriptor)
      state.bytes += data.length().to_int64()
      state.checked[descriptor.digest.to_string()] = data
      data
    }
  }
}

///|
fn walk_descriptor(
  state : WalkState,
  descriptor : @model.Descriptor,
  path : Array[Int32],
  ancestors : Array[@model.Digest],
  inherited_platforms : Array[@model.Platform],
) -> Unit raise @model.MoonOciError {
  state.visits += 1
  if state.visits > state.limits.max_visits ||
    path.length() > state.limits.max_depth {
    raise @model.ResourceLimitExceeded(
      "index traversal visit or depth quota exceeded",
    )
  }
  if descriptor.media_type == @model.media_type_index {
    if ancestors.contains(descriptor.digest) {
      raise @model.InvalidOci("cyclic index reference")
    }
    let index = @codec.decode_index(metadata(state, descriptor))
    require_index(index)
    state.indexes.push({ descriptor, index_path: path.copy(), })
    let next = ancestors.copy()
    next.push(descriptor.digest)
    let platforms = inherited_platforms.copy()
    if descriptor.platform is Some(platform) {
      platforms.push(platform)
    }
    for i, child in index.manifests {
      let child_path = path.copy()
      child_path.push(i)
      walk_descriptor(state, child, child_path, next, platforms)
    }
  } else if descriptor.media_type == @model.media_type_manifest {
    let manifest = @codec.decode_manifest(metadata(state, descriptor))
    if manifest.schema_version != 2 ||
      manifest.media_type != @model.media_type_manifest {
      raise @model.InvalidOci("invalid image manifest in index tree")
    }
    if manifest.config.media_type != @model.media_type_config {
      state.skipped.push({
        descriptor,
        index_path: path,
        reason: "non-image-config",
      })
      return
    }
    let config = @codec.decode_config(metadata(state, manifest.config))
    let platforms = inherited_platforms.copy()
    if descriptor.platform is Some(platform) {
      platforms.push(platform)
    }
    if platforms.any(p => p != config.platform) {
      raise @model.InvalidOci(
        "index platform constraints disagree with image config",
      )
    }
    state.images.push({
      descriptor,
      platform: config.platform,
      index_path: path.copy(),
      ancestor_indexes: ancestors.copy(),
    })
  } else {
    state.skipped.push({
      descriptor,
      index_path: path.copy(),
      reason: "unknown-media-type",
    })
  }
}

///|
/// Materialize a flat image-only view for existing image APIs. Source ordering
/// and leaf annotations are retained; the new root digest differs from the tree.
/// Unknown/non-image entries require an explicit image-only projection choice.
pub fn flatten_images(
  source : @layout.MemoryLayout,
  limits~ : WalkLimits = WalkLimits::default(),
  allow_skipped~ : Bool = false,
) -> @layout.MemoryLayout raise @model.MoonOciError {
  let walk = walk_indexes(source, limits~)
  flatten_walk(source, walk, allow_skipped)
}

///|
fn flatten_walk(
  source : @layout.MemoryLayout,
  walk : IndexWalk,
  allow_skipped : Bool,
) -> @layout.MemoryLayout raise @model.MoonOciError {
  if !walk.complete && !allow_skipped {
    raise @model.Unsupported(
      "index tree contains skipped non-image descriptors",
    )
  }
  let manifests : Array[@model.Descriptor] = []
  let seen : Map[String, Bool] = Map([])
  for image in walk.images {
    let descriptor = { ..image.descriptor, platform: Some(image.platform), }
    let key = @codec.encode_descriptor(descriptor)
    if !seen.contains(key) {
      seen[key] = true
      manifests.push(descriptor)
    }
  }
  let index = @codec.decode_index(source.index())
  let flat_index = @codec.encode_index({ ..index, manifests, })
  let blobs = source.blob_records().map(b => (b.descriptor(), b.data()))
  let candidate = @layout.MemoryLayout::from_untrusted_parts(
    source.marker(),
    flat_index,
    blobs,
  )
  @distribution.compact(candidate)
}
