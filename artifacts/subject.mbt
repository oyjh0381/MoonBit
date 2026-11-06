///|
/// Resolve advertised image/artifact/index metadata, including the anonymous
/// layout root index. Arbitrary unadvertised blob contents are not inferred.
pub fn resolve_subject(
  source : @layout.MemoryLayout,
  digest : @model.Digest,
  limits~ : @graph.WalkLimits = @graph.WalkLimits::default(),
) -> @model.Descriptor raise @model.MoonOciError {
  if source.index().length().to_int64() > limits.max_metadata_bytes {
    raise @model.ResourceLimitExceeded("subject root metadata quota exceeded")
  }
  if @digest.sha256(source.index()) == digest {
    @codec.validate_layout_marker(source.marker())
    let root = @codec.decode_index(source.index())
    if root.schema_version != 2 || root.media_type != @model.media_type_index {
      raise @model.InvalidOci("subject root must be an OCI index")
    }
    return {
      media_type: @model.media_type_index,
      digest,
      size: source.index().length().to_int64(),
      annotations: [],
      platform: None,
    }
  }
  let walk = @graph.walk_indexes(source, limits~)
  let candidates = walk.images.map(item => item.descriptor) +
    walk.indexes.map(item => item.descriptor) +
    walk.skipped
    .filter(item => item.reason == "non-image-config")
    .map(item => item.descriptor)
  for descriptor in candidates {
    if descriptor.digest == digest {
      return descriptor
    }
  }
  raise @model.InvalidArgument("subject not advertised by the layout")
}
