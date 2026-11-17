///|
/// One portable layer changeset supplied to the multi-layer builder.
#derive(Debug, Eq)
pub(all) struct LayerBuildRequest {
  entries : Array[@archive.TarEntry]
  remove : Array[String]
  opaque_dirs : Array[String]
  compression : @model.Compression
}

///|
/// Complete portable request for one single-platform image.
#derive(Debug, Eq)
pub(all) struct ImageBuildRequest {
  layers : Array[LayerBuildRequest]
  platform : @model.Platform
  runtime : @model.RuntimeConfig
  created : String?
  author : String?
  reference : String
  annotations : Array[@model.KeyValue]
}

///|
/// Full result including the effective Root Filesystem view.
#derive(Debug, Eq)
pub(all) struct ImageBuildResult {
  layout : @layout.MemoryLayout
  report : @model.BuildReport
  rootfs : Array[@model.RootfsEntry]
}

///|
/// Build an ordered, deterministic multi-layer OCI Image Layout in memory.
pub fn build_image(
  request : ImageBuildRequest,
) -> ImageBuildResult raise @model.MoonOciError {
  build_image_from_layers(
    request.layers.map(layer => Generated(layer)),
    request.platform,
    request.runtime,
    request.reference,
    created?=request.created,
    author?=request.author,
    annotations=request.annotations,
  )
}

///|
/// A generated changeset or an externally produced, digest-pinned layer.
/// PinnedGzip takes the compressed blob digest followed by the tar DiffID.
#derive(Debug, Eq)
pub(all) enum LayerInput {
  Generated(LayerBuildRequest)
  PinnedTar(Bytes, @model.Digest, @model.Compression)
  PinnedGzip(Bytes, @model.Digest, @model.Digest)
}

///|
pub extend LayerInput with @debug.Debug::{to_repr}

///|
pub extend LayerInput with Eq::{not_equal, equal}

///|
pub let max_imported_layer_tar_bytes : Int32 = 256 * 1024 * 1024

///|
/// Build a deterministic image from an ordered mix of generated and pinned tar layers.
pub fn build_image_from_layers(
  layers : Array[LayerInput],
  platform : @model.Platform,
  runtime : @model.RuntimeConfig,
  reference : String,
  created? : String,
  author? : String,
  annotations~ : Array[@model.KeyValue] = [],
) -> ImageBuildResult raise @model.MoonOciError {
  if reference == "" {
    raise @model.InvalidArgument("image reference must not be empty")
  }
  if layers.length() == 0 {
    raise @model.InvalidArgument("image must contain at least one layer")
  }
  let layout = @layout.MemoryLayout::new()
  let layer_descriptors : Array[@model.Descriptor] = []
  let diff_ids : Array[@model.Digest] = []
  let history : Array[@model.History] = []
  let rootfs = RootfsNode::empty()
  for layer_index, layer in layers {
    let prepared = prepare_layer_input(layer)
    diff_ids.push(prepared.diff_id)
    layer_descriptors.push(layout.put_blob(prepared.media_type, prepared.blob))
    history.push({
      created,
      created_by: Some("moonoci build layer " + layer_index.to_string()),
      author,
      comment: None,
      empty_layer: false,
    })
    rootfs.apply(prepared.transitions, layer_index)
  }
  let config : @model.ImageConfig = {
    created,
    author,
    platform,
    runtime,
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
    annotations,
  }
  let manifest_descriptor = layout.put_blob(
    @model.media_type_manifest,
    @codec.encode_manifest(manifest),
    annotations=[{ key: @model.annotation_ref_name, value: reference, }],
    platform~,
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
    rootfs: rootfs.snapshot(),
  }
}

///|
fn compress_layer(
  layer_tar : Bytes,
  compression : @model.Compression,
  gzip_level~ : Int32 = 0,
) -> (String, Bytes) raise @model.MoonOciError {
  match compression {
    Uncompressed => (@model.media_type_layer_tar, layer_tar)
    Gzip => {
      if layer_tar.length() > 256 * 1024 * 1024 {
        raise @model.ResourceLimitExceeded("gzip build input exceeds 256 MiB")
      }
      let compressed = @fzip.gzip_sync(
        FixedArray::makei(layer_tar.length(), i => layer_tar[i]),
        opts={
          level: gzip_level,
          mem: 0,
          dictionary: None,
          mtime: 0,
          filename: "",
        },
      )
      if exceeds_gzip_layer_ratio(compressed.length(), layer_tar.length()) {
        raise @model.ResourceLimitExceeded(
          "gzip encoding exceeds the 200:1 layer verification limit",
        )
      }
      (@model.media_type_layer_gzip, Bytes::from_array(compressed))
    }
  }
}

///|
pub extend LayerBuildRequest with @debug.Debug::{to_repr}

///|
pub extend LayerBuildRequest with Eq::{not_equal, equal}

///|
pub extend ImageBuildRequest with @debug.Debug::{to_repr}

///|
pub extend ImageBuildRequest with Eq::{not_equal, equal}

///|
pub extend ImageBuildResult with @debug.Debug::{to_repr}

///|
pub extend ImageBuildResult with Eq::{not_equal, equal}

///|
priv struct PreparedLayerInput {
  media_type : String
  blob : Bytes
  diff_id : @model.Digest
  transitions : Array[RootfsTransition]
}

///|
fn prepare_layer_input(
  input : LayerInput,
) -> PreparedLayerInput raise @model.MoonOciError {
  match input {
    Generated(layer) => {
      let transitions = declared_rootfs_transitions(layer)
      let tar_entries = layer.entries.copy()
      for path in layer.remove {
        tar_entries.push(@archive.TarEntry::whiteout(path))
      }
      for path in layer.opaque_dirs {
        tar_entries.push(@archive.TarEntry::opaque_marker(path))
      }
      let (layer_tar, emitted) = @archive.write_tar_with_order(tar_entries)
      let transitions = if tar_entries.any(entry => entry.kind == Hardlink) {
        archived_rootfs_transitions(emitted)
      } else {
        transitions
      }
      let (media_type, blob) = compress_layer(layer_tar, layer.compression)
      { media_type, blob, diff_id: @digest.sha256(layer_tar), transitions, }
    }
    PinnedTar(layer_tar, expected, compression) => {
      let transitions = pinned_tar_transitions(layer_tar, expected)
      let (media_type, blob) = compress_layer(layer_tar, compression)
      { media_type, blob, diff_id: expected, transitions, }
    }
    PinnedGzip(blob, expected_blob, diff_id) => {
      if blob.length() > max_imported_layer_tar_bytes {
        raise @model.ResourceLimitExceeded("imported gzip blob exceeds 256 MiB")
      }
      if @digest.sha256(blob) != expected_blob {
        raise @model.DigestMismatch("imported gzip blob differs from its pin")
      }
      let layer_tar = decode_gzip_layer(blob, max_imported_layer_tar_bytes)
      {
        media_type: @model.media_type_layer_gzip,
        blob,
        diff_id,
        transitions: pinned_tar_transitions(layer_tar, diff_id),
      }
    }
  }
}

///|
fn pinned_tar_transitions(
  layer_tar : Bytes,
  expected : @model.Digest,
) -> Array[RootfsTransition] raise @model.MoonOciError {
  if layer_tar.length() > max_imported_layer_tar_bytes {
    raise @model.ResourceLimitExceeded("imported layer tar exceeds 256 MiB")
  }
  if @digest.sha256(layer_tar) != expected {
    raise @model.DigestMismatch("imported layer DiffID differs from its pin")
  }
  archived_rootfs_transitions(@archive.read_layer_tar(layer_tar))
}
