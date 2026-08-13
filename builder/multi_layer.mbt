///|
/// One portable layer changeset supplied to the multi-layer builder.
pub(all) struct LayerBuildRequest {
  entries : Array[@archive.TarEntry]
  remove : Array[String]
  opaque_dirs : Array[String]
  compression : @model.Compression
} derive(Debug, Eq)

///|
/// Complete portable request for one single-platform image.
pub(all) struct ImageBuildRequest {
  layers : Array[LayerBuildRequest]
  platform : @model.Platform
  runtime : @model.RuntimeConfig
  created : String?
  author : String?
  reference : String
  annotations : Array[@model.KeyValue]
} derive(Debug, Eq)

///|
/// Full result including the effective Root Filesystem view.
pub(all) struct ImageBuildResult {
  layout : @layout.MemoryLayout
  report : @model.BuildReport
  rootfs : Array[@model.RootfsEntry]
} derive(Debug, Eq)

///|
/// Build an ordered, deterministic multi-layer OCI Image Layout in memory.
pub fn build_image(
  request : ImageBuildRequest,
) -> ImageBuildResult raise @model.MoonOciError {
  if request.reference == "" {
    raise @model.InvalidArgument("image reference must not be empty")
  }
  if request.layers.length() == 0 {
    raise @model.InvalidArgument("image must contain at least one layer")
  }
  let layout = @layout.MemoryLayout::new()
  let layer_descriptors : Array[@model.Descriptor] = []
  let diff_ids : Array[@model.Digest] = []
  let history : Array[@model.History] = []
  let mut rootfs : Array[@model.RootfsEntry] = []
  for layer_index, layer in request.layers {
    let transitions = declared_rootfs_transitions(layer)
    let tar_entries = layer.entries.copy()
    for path in layer.remove {
      tar_entries.push(@archive.TarEntry::whiteout(path))
    }
    for path in layer.opaque_dirs {
      tar_entries.push(@archive.TarEntry::opaque_marker(path))
    }
    let layer_tar = @archive.write_tar(tar_entries)
    diff_ids.push(@digest.sha256(layer_tar))
    let (media_type, blob) = compress_layer(layer_tar, layer.compression)
    layer_descriptors.push(layout.put_blob(media_type, blob))
    history.push({
      created: request.created,
      created_by: Some("moonoci build layer " + layer_index.to_string()),
      author: request.author,
      comment: None,
      empty_layer: false,
    })
    rootfs = apply_rootfs_transitions(rootfs, transitions, layer_index)
  }
  let config : @model.ImageConfig = {
    created: request.created,
    author: request.author,
    platform: request.platform,
    runtime: request.runtime,
    diff_ids,
    history,
  }
  let config_descriptor = layout.put_blob(
    @model.media_type_config,
    @codec.encode_config(config),
  )
  let manifest : @model.ImageManifest = {
    schema_version: 2,
    media_type: @model.media_type_manifest,
    config: config_descriptor,
    layers: layer_descriptors,
    annotations: request.annotations,
  }
  let manifest_descriptor = layout.put_blob(
    @model.media_type_manifest,
    @codec.encode_manifest(manifest),
    annotations=[{ key: @model.annotation_ref_name, value: request.reference }],
    platform=request.platform,
  )
  let index : @model.ImageIndex = {
    schema_version: 2,
    media_type: @model.media_type_index,
    manifests: [manifest_descriptor],
    annotations: [],
  }
  layout.set_index(@codec.encode_index(index))
  {
    layout,
    report: {
      manifest: manifest_descriptor,
      config: config_descriptor,
      layers: layer_descriptors,
      blobs_written: layout.blob_count(),
      bytes_written: layout.blob_bytes(),
    },
    rootfs,
  }
}

///|
fn compress_layer(
  layer_tar : Bytes,
  compression : @model.Compression,
) -> (String, Bytes) raise @model.MoonOciError {
  match compression {
    Uncompressed => (@model.media_type_layer_tar, layer_tar)
    Gzip => {
      if layer_tar.length() > 256 * 1024 * 1024 {
        raise @model.ResourceLimitExceeded("gzip build input exceeds 256 MiB")
      }
      let compressed = @fzip.gzip_sync(
        FixedArray::makei(layer_tar.length(), i => layer_tar[i]),
        opts={ level: 0, mem: 0, dictionary: None, mtime: 0, filename: "" },
      )
      (@model.media_type_layer_gzip, Bytes::from_array(compressed))
    }
  }
}
