///|
/// Select one distinct image by its exact config platform, retaining source order
/// for repeated references to the same image. Other media are not asserted valid.
pub fn select_image(
  source : @layout.MemoryLayout,
  platform : @model.Platform,
  limits~ : WalkLimits = WalkLimits::default(),
) -> @layout.MemoryLayout raise @model.MoonOciError {
  let matches = walk_indexes(source, limits~).images.filter(image => {
    image.platform == platform
  })
  if matches.is_empty() {
    raise @model.InvalidArgument("platform absent from index tree")
  }
  let selected = matches[0]
  if matches.any(image => image.descriptor.digest != selected.descriptor.digest) {
    raise @model.InvalidArgument("platform selects multiple distinct images")
  }
  let descriptor = { ..selected.descriptor, platform: Some(selected.platform), }
  let index = @codec.decode_index(source.index())
  let flat_index = @codec.encode_index({ ..index, manifests: [descriptor], })
  let blobs = source
    .blob_records()
    .map(blob => (blob.descriptor(), blob.data()))
  @distribution.compact(
    @layout.MemoryLayout::from_untrusted_parts(
      source.marker(),
      flat_index,
      blobs,
    ),
  )
}

///|
pub fn render_json(walk : IndexWalk) -> String {
  let indexes : Array[Json] = walk.indexes.map(node => {
    "digest": Json::string(node.descriptor.digest.to_string()),
    "index_path": Json::array(
      node.index_path.map(i => Json::number(i.to_double())),
    ),
  })
  let images : Array[Json] = walk.images.map(image => {
    "digest": Json::string(image.descriptor.digest.to_string()),
    "index_path": Json::array(
      image.index_path.map(i => Json::number(i.to_double())),
    ),
    "ancestors": Json::array(
      image.ancestor_indexes.map(d => Json::string(d.to_string())),
    ),
    "os": Json::string(image.platform.os),
    "architecture": Json::string(image.platform.architecture),
    "variant": match image.platform.variant {
      Some(s) => Json::string(s)
      None => Json::null()
    },
    "os_version": match image.platform.os_version {
      Some(s) => Json::string(s)
      None => Json::null()
    },
  })
  let skipped : Array[Json] = walk.skipped.map(item => {
    "digest": Json::string(item.descriptor.digest.to_string()),
    "media_type": Json::string(item.descriptor.media_type),
    "index_path": Json::array(
      item.index_path.map(i => Json::number(i.to_double())),
    ),
    "reason": Json::string(item.reason),
  })
  let result : Json = {
    "schema": "moonoci.index-tree.v1",
    "indexes": Json::array(indexes),
    "complete": Json::boolean(walk.complete),
    "visits": Json::number(walk.visits.to_double()),
    "metadata_bytes": Json::string(walk.metadata_bytes.to_string()),
    "images": Json::array(images),
    "skipped": Json::array(skipped),
  }
  result.stringify()
}
