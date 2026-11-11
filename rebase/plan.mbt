///|
pub(all) struct RebasePins {
  application : @model.Digest
  previous_base : @model.Digest
  replacement_base : @model.Digest
}

///|
pub(all) struct RebaseLayer {
  descriptor : @model.Descriptor
  diff_id : @model.Digest
  from_replacement : Bool
}

///|
pub(all) struct RebasePlan {
  pins : RebasePins
  platform : @model.Platform
  removed_layers : Int32
  layers : Array[RebaseLayer]
}

///|
priv struct ImageInput {
  manifest : @model.ImageManifest
  config : @model.ImageConfig
}

///|
fn load_image(
  source : @layout.MemoryLayout,
  expected : @model.Digest,
) -> ImageInput raise @model.MoonOciError {
  let index = @codec.decode_index(source.index())
  guard index.manifests is [descriptor] &&
    descriptor.media_type == @model.media_type_manifest else {
    raise @model.InvalidArgument(
      "rebase input must advertise exactly one image",
    )
  }
  if descriptor.digest != expected {
    raise @model.DigestMismatch("rebase input manifest pin mismatch")
  }
  let manifest = @codec.decode_manifest(source.require_blob(descriptor))
  if manifest.layers.is_empty() ||
    manifest.layers.length() > 128 ||
    source.blob_bytes() > 536870912L {
    raise @model.ResourceLimitExceeded(
      "rebase input exceeds the layer or byte budget",
    )
  }
  if !@builder.verify_memory(source).is_valid() {
    raise @model.InvalidOci("rebase input fails image and DiffID verification")
  }
  let config = @codec.decode_config(source.require_blob(manifest.config))
  if descriptor.platform is Some(platform) && platform != config.platform {
    raise @model.InvalidOci("rebase input platform disagrees with image config")
  }
  { manifest, config, }
}

///|
/// Verify the exact application and two base manifests, then prove the old
/// base's uncompressed layer identities are a prefix of the application.
/// The plan describes layer reuse and does not assert runtime compatibility.
pub fn plan_rebase(
  application : @layout.MemoryLayout,
  previous_base : @layout.MemoryLayout,
  replacement_base : @layout.MemoryLayout,
  pins : RebasePins,
) -> RebasePlan raise @model.MoonOciError {
  let app = load_image(application, pins.application)
  let old = load_image(previous_base, pins.previous_base)
  let replacement = load_image(replacement_base, pins.replacement_base)
  plan_inputs(app, old, replacement, pins)
}

///|
fn plan_inputs(
  app : ImageInput,
  old : ImageInput,
  replacement : ImageInput,
  pins : RebasePins,
) -> RebasePlan raise @model.MoonOciError {
  let platform = app.config.platform
  if old.config.platform != platform || replacement.config.platform != platform {
    raise @model.InvalidArgument("rebase inputs require one exact platform")
  }
  if app.manifest.annotations.any(annotation => {
      annotation.key == "org.opencontainers.image.base.digest" &&
      annotation.value != pins.previous_base.to_string()
    }) {
    raise @model.DigestMismatch(
      "application base annotation contradicts the expected previous base",
    )
  }
  let removed_layers = old.config.diff_ids.length()
  if removed_layers > app.config.diff_ids.length() {
    raise @model.InvalidOci(
      "previous base is longer than the application layer chain",
    )
  }
  for i, diff_id in old.config.diff_ids {
    if diff_id != app.config.diff_ids[i] {
      raise @model.DigestMismatch(
        "previous base DiffID is not a prefix of the application",
      )
    }
  }
  let layers : Array[RebaseLayer] = []
  for i, descriptor in replacement.manifest.layers {
    layers.push({
      descriptor,
      diff_id: replacement.config.diff_ids[i],
      from_replacement: true,
    })
  }
  for i in removed_layers..<app.manifest.layers.length() {
    layers.push({
      descriptor: app.manifest.layers[i],
      diff_id: app.config.diff_ids[i],
      from_replacement: false,
    })
  }
  if layers.length() > 128 {
    raise @model.ResourceLimitExceeded("rebased chain exceeds 128 layers")
  }
  { pins, platform, removed_layers, layers, }
}
