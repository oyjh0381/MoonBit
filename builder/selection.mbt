///|
fn require_root_manifest(
  source : @layout.MemoryLayout,
  descriptor : @model.Descriptor,
) -> @model.ImageManifest raise @model.MoonOciError {
  if !verify_memory(source).is_valid() {
    raise @model.InvalidOci("filesystem query requires a verified graph")
  }
  if !@codec.decode_index(source.index()).manifests.contains(descriptor) {
    raise @model.InvalidArgument(
      "filesystem manifest must be a root index member",
    )
  }
  let manifest = @codec.decode_manifest(source.require_blob(descriptor))
  let config = @codec.decode_config(source.require_blob(manifest.config))
  if descriptor.platform is Some(platform) {
    if platform != config.platform {
      raise @model.InvalidOci("filesystem platform disagrees with config")
    }
  }
  manifest
}
