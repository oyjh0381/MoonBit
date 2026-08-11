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
    validate_changeset(layer)
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
    rootfs = apply_changeset(rootfs, layer, layer_index)
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

///|
fn validate_changeset(
  layer : LayerBuildRequest,
) -> Unit raise @model.MoonOciError {
  for entry in layer.entries {
    if @pathing.is_whiteout_path(entry.path) {
      raise @model.InvalidArgument(
        "layer additions must not use reserved Whiteout paths: " + entry.path,
      )
    }
  }
  for removed in layer.remove {
    let normalized = @pathing.normalize_spec_path(removed)
    for entry in layer.entries {
      if entry.path == normalized {
        raise @model.InvalidArgument(
          "layer cannot add and remove the same path: " + normalized,
        )
      }
    }
  }
  for directory in layer.opaque_dirs {
    ignore(@pathing.normalize_spec_path(directory))
  }
}

///|
fn apply_changeset(
  current : Array[@model.RootfsEntry],
  layer : LayerBuildRequest,
  layer_index : Int,
) -> Array[@model.RootfsEntry] raise @model.MoonOciError {
  let mut result = current
  for directory in layer.opaque_dirs {
    let normalized = @pathing.normalize_spec_path(directory)
    result = filter_children(result, normalized, true)
  }
  for path in layer.remove {
    let normalized = @pathing.normalize_spec_path(path)
    result = filter_children(result, normalized, false)
  }
  let sorted_entries = layer.entries.copy()
  sorted_entries.sort_by((a, b) => @pathing.compare_utf8(a.path, b.path))
  for entry in sorted_entries {
    validate_parent_chain(result, entry.path)
    result = match entry.kind {
      Directory => filter_exact(result, entry.path)
      Regular | Symlink => filter_children(result, entry.path, false)
    }
    let kind = match entry.kind {
      Regular => "file"
      Directory => "directory"
      Symlink => "symlink"
    }
    result.push({
      path: entry.path,
      kind,
      mode: entry.mode,
      size: entry.size(),
      link_target: entry.link_target,
      layer_index,
    })
  }
  result.sort_by((a, b) => @pathing.compare_utf8(a.path, b.path))
  result
}

///|
fn filter_exact(
  entries : Array[@model.RootfsEntry],
  path : String,
) -> Array[@model.RootfsEntry] {
  entries.filter(entry => entry.path != path)
}

///|
fn filter_children(
  entries : Array[@model.RootfsEntry],
  path : String,
  keep_parent : Bool,
) -> Array[@model.RootfsEntry] {
  let result : Array[@model.RootfsEntry] = []
  let prefix = path + "/"
  for entry in entries {
    let remove = entry.path.has_prefix(prefix) ||
      (!keep_parent && entry.path == path)
    if !remove {
      result.push(entry)
    }
  }
  result
}

///|
fn validate_parent_chain(
  entries : Array[@model.RootfsEntry],
  path : String,
) -> Unit raise @model.MoonOciError {
  let segments = path.split("/").map(part => part.to_owned()).collect()
  for end in 1..<segments.length() {
    let parent = segments[0:end].to_owned().join("/")
    for existing in entries {
      if existing.path == parent && existing.kind != "directory" {
        raise @model.InvalidOci(
          "cannot add child beneath non-directory path: " + parent,
        )
      }
    }
  }
}
