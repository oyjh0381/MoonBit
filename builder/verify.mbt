///|
/// Verify the complete Descriptor graph of a portable in-memory layout.
pub fn verify_memory(
  layout : @layout.MemoryLayout,
) -> @model.VerificationReport {
  let findings : Array[@model.ValidationFinding] = []
  @codec.validate_layout_marker(layout.marker()) catch {
    error => {
      push_verification_error(findings, error, "oci-layout")
      return empty_verification_report(findings)
    }
  }
  if layout.index().length() == 0 {
    push_verification_error(
      findings,
      @model.InvalidOci("index.json is empty"),
      "index.json",
    )
    return empty_verification_report(findings)
  }
  let index = @codec.decode_index(layout.index()) catch {
    error => {
      push_verification_error(findings, error, "index.json")
      return empty_verification_report(findings)
    }
  }
  if index.schema_version != 2 {
    push_verification_error(
      findings,
      @model.InvalidOci("image index schemaVersion must be 2"),
      "index.json.schemaVersion",
    )
  }
  require_media_type("image index", index.media_type, @model.media_type_index) catch {
    error => push_verification_error(findings, error, "index.json.mediaType")
  }
  let mut manifests_checked = 0
  let mut blobs_checked = 0
  let mut layers_checked = 0
  for manifest_index, descriptor in index.manifests {
    let counts = verify_manifest_branch(
      layout, descriptor, manifest_index, findings,
    )
    manifests_checked += counts.manifests
    blobs_checked += counts.blobs
    layers_checked += counts.layers
  }
  { findings, manifests_checked, blobs_checked, layers_checked, }
}

///|
priv struct VerificationCounts {
  manifests : Int32
  blobs : Int32
  layers : Int32
}

///|
fn verify_manifest_branch(
  layout : @layout.MemoryLayout,
  manifest_descriptor : @model.Descriptor,
  manifest_index : Int32,
  findings : Array[@model.ValidationFinding],
) -> VerificationCounts {
  let manifest_path = "index.manifests[" + manifest_index.to_string() + "]"
  let mut branch_valid = true
  let mut blobs_checked = 0
  let mut layers_checked = 0
  require_media_type(
    "manifest descriptor",
    manifest_descriptor.media_type,
    @model.media_type_manifest,
  ) catch {
    error => {
      push_verification_error(findings, error, manifest_path + ".mediaType")
      branch_valid = false
    }
  }
  let manifest_data = match
    require_blob_for_report(
      layout, manifest_descriptor, findings, manifest_path,
    ) {
    Some(data) => {
      blobs_checked += 1
      data
    }
    None => return { manifests: 0, blobs: blobs_checked, layers: 0, }
  }
  let manifest = @codec.decode_manifest(manifest_data) catch {
    error => {
      push_verification_error(findings, error, manifest_path)
      return { manifests: 0, blobs: blobs_checked, layers: 0, }
    }
  }
  if manifest.schema_version != 2 {
    push_verification_error(
      findings,
      @model.InvalidOci("image manifest schemaVersion must be 2"),
      manifest_path + ".schemaVersion",
    )
    branch_valid = false
  }
  require_media_type(
    "image manifest",
    manifest.media_type,
    @model.media_type_manifest,
  ) catch {
    error => {
      push_verification_error(findings, error, manifest_path + ".mediaType")
      branch_valid = false
    }
  }
  let config_path = manifest_path + ".config"
  require_media_type(
    "configuration descriptor",
    manifest.config.media_type,
    @model.media_type_config,
  ) catch {
    error => {
      push_verification_error(findings, error, config_path + ".mediaType")
      branch_valid = false
    }
  }
  let mut config : @model.ImageConfig? = None
  match
    require_blob_for_report(layout, manifest.config, findings, config_path) {
    Some(config_data) => {
      blobs_checked += 1
      config = decode_config_for_report(config_data, findings, config_path)
      if config is None {
        branch_valid = false
      }
    }
    None => branch_valid = false
  }
  match config {
    Some(value) =>
      if value.diff_ids.length() != manifest.layers.length() {
        push_verification_error(
          findings,
          @model.InvalidOci("rootfs DiffID count does not match layer count"),
          config_path + ".rootfs.diff_ids",
        )
        branch_valid = false
      }
    None => ()
  }
  let mut rootfs = Some(RootfsNode::empty())
  for layer_index, layer in manifest.layers {
    let layer_path = manifest_path + ".layers[" + layer_index.to_string() + "]"
    require_media_type(
      "layer descriptor",
      layer.media_type,
      supported_layer_media_type(layer.media_type),
    ) catch {
      error => {
        push_verification_error(findings, error, layer_path + ".mediaType")
        branch_valid = false
        rootfs = None
        continue
      }
    }
    let layer_data = match
      require_blob_for_report(layout, layer, findings, layer_path) {
      Some(data) => {
        blobs_checked += 1
        data
      }
      None => {
        branch_valid = false
        rootfs = None
        continue
      }
    }
    let interpretation = interpret_layer_blob(layer.media_type, layer_data) catch {
      error => {
        push_verification_error(findings, error, layer_path)
        branch_valid = false
        rootfs = None
        continue
      }
    }
    if rootfs is Some(tree) {
      tree.apply(
        archived_rootfs_transitions(interpretation.entries),
        layer_index,
      ) catch {
        error => {
          push_verification_error(findings, error, layer_path)
          branch_valid = false
          rootfs = None
        }
      }
    }
    let expected_diff_id = match config {
      Some(value) if layer_index < value.diff_ids.length() =>
        Some(value.diff_ids[layer_index])
      _ => None
    }
    match expected_diff_id {
      Some(expected) =>
        if interpretation.diff_id() != expected {
          push_verification_error(
            findings,
            @model.DigestMismatch(
              "layer DiffID mismatch at index " + layer_index.to_string(),
            ),
            layer_path,
          )
          branch_valid = false
        } else {
          layers_checked += 1
        }
      None => branch_valid = false
    }
  }
  {
    manifests: if branch_valid {
      1
    } else {
      0
    },
    blobs: blobs_checked,
    layers: layers_checked,
  }
}

///|
fn supported_layer_media_type(
  actual : String,
) -> String raise @model.MoonOciError {
  if actual == @model.media_type_layer_tar ||
    actual == @model.media_type_layer_gzip {
    actual
  } else {
    raise @model.Unsupported("unsupported layer media type: " + actual)
  }
}

///|
fn require_blob_for_report(
  layout : @layout.MemoryLayout,
  descriptor : @model.Descriptor,
  findings : Array[@model.ValidationFinding],
  path : String,
) -> Bytes? {
  Some(layout.require_blob(descriptor)) catch {
    error => {
      push_verification_error(findings, error, path)
      None
    }
  }
}

///|
fn decode_config_for_report(
  data : Bytes,
  findings : Array[@model.ValidationFinding],
  path : String,
) -> @model.ImageConfig? {
  Some(@codec.decode_config(data)) catch {
    error => {
      push_verification_error(findings, error, path)
      None
    }
  }
}

///|
fn push_verification_error(
  findings : Array[@model.ValidationFinding],
  error : @model.MoonOciError,
  path : String,
) -> Unit {
  findings.push({
    level: @model.FindingLevel::Error,
    code: error.code(),
    message: error.message(),
    object_path: Some(path),
  })
}

///|
fn empty_verification_report(
  findings : Array[@model.ValidationFinding],
) -> @model.VerificationReport {
  { findings, manifests_checked: 0, blobs_checked: 0, layers_checked: 0, }
}

///|
fn require_media_type(
  object : String,
  actual : String,
  expected : String,
) -> Unit raise @model.MoonOciError {
  if actual != expected {
    raise @model.InvalidOci(
      object + " media type must be " + expected + ", got " + actual,
    )
  }
}

///|
/// Reconstruct a single-image layout. Multi-image layouts require explicit
/// manifest selection through rootfs_from_manifest instead of guessing.
pub fn rootfs_from_layout(
  layout : @layout.MemoryLayout,
) -> Array[@model.RootfsEntry] raise @model.MoonOciError {
  let index = @codec.decode_index(layout.index())
  if index.manifests.length() != 1 {
    raise @model.InvalidArgument(
      "filesystem query requires exactly one image or explicit manifest selection",
    )
  }
  rootfs_from_manifest(layout, index.manifests[0])
}

///|
pub fn rootfs_from_manifest(
  layout : @layout.MemoryLayout,
  descriptor : @model.Descriptor,
) -> Array[@model.RootfsEntry] raise @model.MoonOciError {
  let manifest = require_root_manifest(layout, descriptor)
  let rootfs = RootfsNode::empty()
  for layer_index, descriptor in manifest.layers {
    let interpretation = interpret_layer_blob(
      descriptor.media_type,
      layout.require_blob(descriptor),
    )
    let transitions = archived_rootfs_transitions(interpretation.entries)
    rootfs.apply(transitions, layer_index)
  }
  rootfs.snapshot()
}
