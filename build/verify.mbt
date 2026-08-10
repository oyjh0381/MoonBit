///|
/// Verify the complete Descriptor graph of a portable in-memory layout.
pub fn verify_memory(
  layout : @layout.MemoryLayout,
) -> @model.VerificationReport {
  verify_memory_strict(layout) catch {
    error =>
      {
        findings: [
          {
            level: @model.FindingLevel::Error,
            code: error.code(),
            message: error.message(),
            object_path: Some("layout"),
          },
        ],
        manifests_checked: 0,
        blobs_checked: 0,
        layers_checked: 0,
      }
  }
}

///|
fn verify_memory_strict(
  layout : @layout.MemoryLayout,
) -> @model.VerificationReport raise @model.MoonOciError {
  @codec.validate_layout_marker(layout.marker())
  if layout.index().length() == 0 {
    raise @model.InvalidOci("index.json is empty")
  }
  let index = @codec.decode_index(layout.index())
  if index.schema_version != 2 {
    raise @model.InvalidOci("image index schemaVersion must be 2")
  }
  let mut manifests_checked = 0
  let mut blobs_checked = 0
  let mut layers_checked = 0
  let findings : Array[@model.ValidationFinding] = []
  for manifest_descriptor in index.manifests {
    let manifest_data = layout.require_blob(manifest_descriptor)
    blobs_checked += 1
    let manifest = @codec.decode_manifest(manifest_data)
    if manifest.schema_version != 2 {
      raise @model.InvalidOci("image manifest schemaVersion must be 2")
    }
    manifests_checked += 1
    let config_data = layout.require_blob(manifest.config)
    blobs_checked += 1
    let config = @codec.decode_config(config_data)
    if config.diff_ids.length() != manifest.layers.length() {
      raise @model.InvalidOci("rootfs DiffID count does not match layer count")
    }
    for i, layer in manifest.layers {
      let layer_data = layout.require_blob(layer)
      blobs_checked += 1
      if layer.media_type == @model.media_type_layer_tar ||
        layer.media_type == @model.media_type_layer_gzip {
        let uncompressed = decode_layer_blob(layer.media_type, layer_data)
        ignore(@archive.read_tar(uncompressed))
        if @digest.sha256(uncompressed) != config.diff_ids[i] {
          raise @model.DigestMismatch(
            "layer DiffID mismatch at index " + i.to_string(),
          )
        }
      } else {
        findings.push({
          level: @model.FindingLevel::Warning,
          code: "MOONOCI_UNSUPPORTED_LAYER_MEDIA_TYPE",
          message: "semantic layer verification skipped for " + layer.media_type,
          object_path: Some(layer.digest.blob_path()),
        })
      }
      layers_checked += 1
    }
  }
  { findings, manifests_checked, blobs_checked, layers_checked }
}

///|
/// Decode a supported Layer Blob under verification resource limits.
pub fn decode_layer_blob(
  media_type : String,
  data : Bytes,
) -> Bytes raise @model.MoonOciError {
  if media_type == @model.media_type_layer_tar {
    return data
  }
  if media_type != @model.media_type_layer_gzip {
    raise @model.Unsupported("unsupported layer media type: " + media_type)
  }
  let max_size = 512 * 1024 * 1024
  let uncompressed = @zlib.gzip_decompress(data, max_size~) catch {
    _ => raise @model.InvalidTar("cannot decompress gzip layer")
  }
  if data.length() > 0 &&
    uncompressed.length().to_int64() > data.length().to_int64() * 200L {
    raise @model.ResourceLimitExceeded(
      "gzip layer exceeds 200:1 expansion ratio",
    )
  }
  uncompressed
}

///|
/// Reconstruct the effective Root Filesystem from the first manifest.
pub fn rootfs_from_layout(
  layout : @layout.MemoryLayout,
) -> Array[@model.RootfsEntry] raise @model.MoonOciError {
  let index = @codec.decode_index(layout.index())
  if index.manifests.length() == 0 {
    raise @model.InvalidOci("image index contains no manifests")
  }
  let manifest = @codec.decode_manifest(layout.require_blob(index.manifests[0]))
  let mut rootfs : Array[@model.RootfsEntry] = []
  for layer_index, descriptor in manifest.layers {
    let data = decode_layer_blob(
      descriptor.media_type,
      layout.require_blob(descriptor),
    )
    for entry in @archive.read_tar(data) {
      if entry.path.has_suffix("/.wh..wh..opq") || entry.path == ".wh..wh..opq" {
        let directory = if entry.path == ".wh..wh..opq" {
          ""
        } else {
          entry.path[0:entry.path.length() - "/.wh..wh..opq".length()].to_owned()
        }
        rootfs = if directory == "" {
          []
        } else {
          filter_children(rootfs, directory, true)
        }
      } else {
        let segments = entry.path
          .split("/")
          .map(part => part.to_owned())
          .collect()
        let basename = segments[segments.length() - 1]
        if basename.has_prefix(".wh.") {
          let target_name = basename[4:].to_owned()
          let target = if segments.length() == 1 {
            target_name
          } else {
            segments[0:segments.length() - 1].to_owned().join("/") +
            "/" +
            target_name
          }
          rootfs = filter_children(rootfs, target, false)
        } else {
          validate_parent_chain(rootfs, entry.path)
          rootfs = match entry.kind {
            Directory => filter_exact(rootfs, entry.path)
            Regular | Symlink => filter_children(rootfs, entry.path, false)
          }
          let kind = match entry.kind {
            Regular => "file"
            Directory => "directory"
            Symlink => "symlink"
          }
          rootfs.push({
            path: entry.path,
            kind,
            mode: entry.mode,
            size: entry.size(),
            link_target: entry.link_target,
            layer_index,
          })
        }
      }
    }
  }
  rootfs.sort_by((a, b) => @pathing.compare_utf8(a.path, b.path))
  rootfs
}
