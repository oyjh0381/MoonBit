///|
/// Where verified image layer sequences first disagree. A missing side means
/// its sequence ended at this zero-based position.
pub(all) struct LayerDifference {
  position : Int32
  before_diff_id : @model.Digest?
  after_diff_id : @model.Digest?
}

///|
/// Compare the ordered uncompressed filesystem identities of two verified
/// root images. OCI layer encoding does not affect this comparison.
pub fn compare_layer_order(
  before : @layout.MemoryLayout,
  before_pin : @model.Digest,
  after : @layout.MemoryLayout,
  after_pin : @model.Digest,
) -> LayerDifference? raise @model.MoonOciError {
  let (_, _, before_ids) = verified_storage_image(before, before_pin)
  let (_, _, after_ids) = verified_storage_image(after, after_pin)
  first_layer_difference(before_ids, after_ids)
}

///|
fn verified_storage_image(
  layout : @layout.MemoryLayout,
  pin : @model.Digest,
) -> (@model.Descriptor, @model.ImageManifest, Array[@model.Digest]) raise @model.MoonOciError {
  let entries = @codec.decode_index(layout.index()).manifests
  guard entries.filter(item => item.digest == pin) is [descriptor] else {
    raise @model.InvalidArgument("comparison requires one exact root image")
  }
  let manifest = require_root_manifest(layout, descriptor)
  let config = @codec.decode_config(layout.require_blob(manifest.config))
  (descriptor, manifest, config.diff_ids)
}

///|
fn first_layer_difference(
  before : Array[@model.Digest],
  after : Array[@model.Digest],
) -> LayerDifference? {
  let length = if before.length() > after.length() {
    before.length()
  } else {
    after.length()
  }
  for position in 0..<length {
    let left = before.get(position)
    let right = after.get(position)
    if left != right {
      return Some({ position, before_diff_id: left, after_diff_id: right, })
    }
  }
  None
}
