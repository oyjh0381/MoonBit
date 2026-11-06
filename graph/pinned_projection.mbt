///|
/// Unsigned record binding a source tree to its image-only derived layout.
pub(all) struct ProjectionReceipt {
  source_index : @model.Digest
  projected_index : @model.Digest
  image_manifests : Array[@model.Digest]
  skipped_descriptors : Int32
}

///|
pub(all) struct PinnedProjection {
  layout : @layout.MemoryLayout
  receipt : ProjectionReceipt
}

///|
/// Check the externally trusted source pin before parsing or fetching metadata.
pub fn walk_pinned(
  source : @layout.MemoryLayout,
  expected : @model.Digest,
  limits~ : WalkLimits = WalkLimits::default(),
) -> IndexWalk raise @model.MoonOciError {
  if @digest.sha256(source.index()) != expected {
    raise @model.DigestMismatch("index tree root pin mismatch")
  }
  walk_indexes(source, limits~)
}

///|
/// Host authenticates the source pin and stores/signs the recomputed receipt.
pub fn project_pinned(
  source : @layout.MemoryLayout,
  expected : @model.Digest,
  limits~ : WalkLimits = WalkLimits::default(),
  allow_skipped~ : Bool = false,
) -> PinnedProjection raise @model.MoonOciError {
  let walk = walk_pinned(source, expected, limits~)
  let result = flatten_walk(source, walk, allow_skipped)
  let index = @codec.decode_index(result.index())
  {
    layout: result,
    receipt: {
      source_index: expected,
      projected_index: @digest.sha256(result.index()),
      image_manifests: index.manifests.map(d => d.digest),
      skipped_descriptors: walk.skipped.length(),
    },
  }
}

///|
pub fn receipt_json(receipt : ProjectionReceipt) -> String {
  let result : Json = {
    "schema": "moonoci.projection.v1",
    "source_index": Json::string(receipt.source_index.to_string()),
    "projected_index": Json::string(receipt.projected_index.to_string()),
    "image_manifests": Json::array(
      receipt.image_manifests.map(d => Json::string(d.to_string())),
    ),
    "skipped_descriptors": Json::number(receipt.skipped_descriptors.to_double()),
  }
  result.stringify()
}
