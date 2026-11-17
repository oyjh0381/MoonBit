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

///|
/// Compare config bytes and ordered tar identities of pinned OCI root images.
pub(all) struct ImageStorageComparison {
  before_config : @model.Digest
  after_config : @model.Digest
  first_layer_difference : LayerDifference?
  before_layer_bytes : Int64
  after_layer_bytes : Int64
  new_layer_count : Int32
  new_layer_bytes : Int64
  before_image_blob_bytes : Int64
  after_image_blob_bytes : Int64
  new_image_blob_bytes : Int64
}

///|
/// True when config bytes and the entire ordered DiffID sequence are identical.
pub fn ImageStorageComparison::preserves_runtime_identity(
  self : ImageStorageComparison,
) -> Bool {
  self.before_config == self.after_config && self.first_layer_difference is None
}

///|
/// Compare two verified images by manifest pin. Config metadata changes are
/// visible even when the two images have exactly the same ordered layers.
pub fn compare_image_storage(
  before : @layout.MemoryLayout,
  before_pin : @model.Digest,
  after : @layout.MemoryLayout,
  after_pin : @model.Digest,
) -> ImageStorageComparison raise @model.MoonOciError {
  let (before_descriptor, before_manifest, before_ids) = verified_storage_image(
    before, before_pin,
  )
  let (after_descriptor, after_manifest, after_ids) = verified_storage_image(
    after, after_pin,
  )
  let before_sizes = unique_layer_sizes(before_manifest.layers)
  let after_sizes = unique_layer_sizes(after_manifest.layers)
  let mut new_layer_count = 0
  let mut new_layer_bytes = 0L
  for digest, size in after_sizes {
    if !before_sizes.contains(digest) {
      new_layer_count += 1
      new_layer_bytes += size
    }
  }
  let before_layer_bytes = before_sizes
    .values()
    .fold(init=0L, (total, size) => total + size)
  let after_layer_bytes = after_sizes
    .values()
    .fold(init=0L, (total, size) => total + size)
  let mut before_image_blob_bytes = before_layer_bytes
  for item in [before_descriptor, before_manifest.config] {
    let key = item.digest.to_string()
    if !before_sizes.contains(key) {
      before_image_blob_bytes += item.size
      before_sizes[key] = item.size
    }
  }
  let mut after_image_blob_bytes = after_layer_bytes
  let mut new_image_blob_bytes = after_sizes
    .iter()
    .fold(init=0L, (bytes, pair) => {
      let (key, size) = pair
      if before_sizes.contains(key) {
        bytes
      } else {
        bytes + size
      }
    })
  for item in [after_descriptor, after_manifest.config] {
    let key = item.digest.to_string()
    if !after_sizes.contains(key) {
      after_image_blob_bytes += item.size
      after_sizes[key] = item.size
      if !before_sizes.contains(key) {
        new_image_blob_bytes += item.size
      }
    }
  }
  {
    before_config: before_manifest.config.digest,
    after_config: after_manifest.config.digest,
    first_layer_difference: first_layer_difference(before_ids, after_ids),
    before_layer_bytes,
    after_layer_bytes,
    new_layer_count,
    new_layer_bytes,
    before_image_blob_bytes,
    after_image_blob_bytes,
    new_image_blob_bytes,
  }
}

///|
fn unique_layer_sizes(layers : Array[@model.Descriptor]) -> Map[String, Int64] {
  let sizes : Map[String, Int64] = Map([])
  for layer in layers {
    sizes[layer.digest.to_string()] = layer.size
  }
  sizes
}
