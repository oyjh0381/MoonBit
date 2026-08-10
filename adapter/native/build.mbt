///|
/// Build a Native OCI Image Layout from a Build Specification file.
pub async fn build_from_file(spec_path : String) -> @build.ImageBuildResult {
  if !@fs.exists(spec_path) {
    raise @model.IoFailure("Build Specification does not exist: " + spec_path)
  }
  let spec = @spec.parse_build_spec(@fs.read_file(spec_path).binary())
  let layers : Array[@build.LayerBuildRequest] = []
  for layer in spec.layers {
    let entries = collect_layer_source(layer.source, layer)
    layers.push({
      entries,
      remove: layer.remove,
      opaque_dirs: layer.opaque_dirs,
      compression: layer.compression,
    })
  }
  let result = @build.build_image({
    layers,
    platform: spec.platform,
    runtime: spec.runtime,
    created: spec.created,
    author: spec.author,
    reference: spec.reference,
    annotations: spec.annotations,
  })
  write_layout(spec.output.layout, result.layout)
  result
}

///|
/// Materialize an in-memory layout through a staging directory and rename.
pub async fn write_layout(
  destination : String,
  layout : @layout.MemoryLayout,
) -> Unit {
  if destination == "" {
    raise @model.InvalidArgument("layout destination must not be empty")
  }
  if @fs.exists(destination) {
    raise @model.IoFailure("layout destination already exists: " + destination)
  }
  let staging = destination + ".moonoci-staging"
  if @fs.exists(staging) {
    raise @model.IoFailure("staging destination already exists: " + staging)
  }
  try {
    @fs.mkdir(join_path(staging, "blobs/sha256"), recursive=true)
    @fs.write_file(
      join_path(staging, "oci-layout"),
      layout.marker,
      create_mode=CreateOrTruncate,
    )
    @fs.write_file(
      join_path(staging, "index.json"),
      layout.index,
      create_mode=CreateOrTruncate,
    )
    for blob in layout.blobs {
      @fs.write_file(
        join_path(staging, blob.descriptor.digest.blob_path()),
        blob.data,
        create_mode=CreateOrTruncate,
      )
    }
    @fs.rename(staging, destination, replace=false)
  } catch {
    error => {
      if @fs.exists(staging) {
        @fs.rmdir(staging, recursive=true) catch {
          _ => ()
        }
      }
      raise @model.IoFailure("cannot write OCI Image Layout: \{error}")
    }
  }
}
