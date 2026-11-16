///|
/// Publishable result of a verified single-platform storage conversion.
/// Layer byte counts sum unique stored layer blobs in the selected image.
pub(all) struct ImageTranscode {
  layout : @layout.MemoryLayout
  manifest : @model.Descriptor
  converted_layers : Int32
  source_layer_bytes : Int64
  result_layer_bytes : Int64
}

///|
/// Derive a standalone selected image whose config and uncompressed layers
/// are byte-identical to the source. The supplied manifest pin selects the image.
/// If present, positions selects a nonempty set of zero-based layer positions.
pub fn transcode_image(
  source : @layout.MemoryLayout,
  expected : @model.Digest,
  compression : @model.Compression,
  positions? : Array[Int32],
  max_result_layer_bytes~ : Int64 = 0x7fffffffffffffffL,
) -> ImageTranscode raise @model.MoonOciError {
  if max_result_layer_bytes < 0L {
    raise @model.InvalidArgument(
      "transcode layer byte limit cannot be negative",
    )
  }
  let index = @codec.decode_index(source.index())
  let matches = index.manifests.filter(item => item.digest == expected)
  guard matches is [descriptor] else {
    raise @model.InvalidArgument("transcode requires one exact index member")
  }
  let manifest = require_root_manifest(source, descriptor)
  let selected = Map([])
  if positions is Some(values) {
    if values.is_empty() {
      raise @model.InvalidArgument(
        "transcode requires at least one selected layer position",
      )
    }
    for position in values {
      if position < 0 ||
        position >= manifest.layers.length() ||
        selected.contains(position) {
        raise @model.InvalidArgument(
          "duplicate or out-of-range transcode layer position",
        )
      }
      selected[position] = true
    }
  }
  let original = source.require_blob(descriptor)
  guard @codec.parse_json_document(original, preserve_number_repr=true)
    is Object(fields) &&
    fields.get("layers") is Some(Array(raw_layers)) &&
    raw_layers.length() == manifest.layers.length() else {
    raise @model.InvalidOci("transcode requires manifest layer descriptors")
  }
  if fields.contains("subject") || fields.contains("artifactType") {
    raise @model.Unsupported("transcode requires a plain OCI image")
  }
  let config_data = source.require_blob(manifest.config)
  let config = @codec.decode_config(config_data)
  let result = @layout.MemoryLayout::new()
  ignore(result.put_blob(manifest.config.media_type, config_data))
  let mut converted_layers = 0
  let seen_input : Map[String, Bool] = Map([])
  let seen_output : Map[String, Bool] = Map([])
  let mut source_layer_bytes = 0L
  let mut result_layer_bytes = 0L
  let transcoded : Map[String, LayerTranscode] = Map([])
  let target_media = match compression {
    Uncompressed => @model.media_type_layer_tar
    Gzip => @model.media_type_layer_gzip
  }
  for index, layer in manifest.layers {
    let data = source.require_blob(layer)
    let input_key = layer.digest.to_string()
    if !seen_input.contains(input_key) {
      seen_input[input_key] = true
      source_layer_bytes += layer.size
    }
    let diff_id = config.diff_ids[index]
    let converted : LayerTranscode = if layer.media_type == target_media ||
      (positions is Some(_) && !selected.contains(index)) {
      { media_type: layer.media_type, data, digest: layer.digest, diff_id, }
    } else {
      let key = input_key + "|" + layer.media_type
      match transcoded.get(key) {
        Some(previous) => {
          if previous.diff_id != diff_id {
            raise @model.DigestMismatch(
              "same layer blob declares conflicting DiffIDs",
            )
          }
          previous
        }
        None => {
          let next = transcode_layer_blob(layer, data, diff_id, compression)
          transcoded[key] = next
          next
        }
      }
    }
    if converted.digest != layer.digest ||
      converted.media_type != layer.media_type {
      guard raw_layers[index] is Object(raw) else {
        raise @model.InvalidOci("invalid raw layer descriptor")
      }
      replace_storage(
        raw,
        converted.digest,
        converted.media_type,
        converted.data.length(),
      )
      converted_layers += 1
    }
    let output_key = converted.digest.to_string()
    if !seen_output.contains(output_key) {
      let size = converted.data.length().to_int64()
      if size > max_result_layer_bytes - result_layer_bytes {
        raise @model.ResourceLimitExceeded(
          "transcode output exceeds the layer storage budget",
        )
      }
      seen_output[output_key] = true
      result_layer_bytes += size
      ignore(result.put_blob(converted.media_type, converted.data))
    }
  }
  let manifest_data = if converted_layers == 0 {
    original
  } else {
    @utf8.encode(Json::object(fields).stringify())
  }
  let emitted = result.put_blob(
    descriptor.media_type,
    manifest_data,
    annotations=descriptor.annotations,
    platform?=descriptor.platform,
  )
  result.set_index(rewrite_transcode_index(source.index(), expected, emitted))
  if !verify_memory(result).is_valid() {
    raise @model.InvalidOci("derived image failed verification")
  }
  {
    layout: result,
    manifest: emitted,
    converted_layers,
    source_layer_bytes,
    result_layer_bytes,
  }
}

///|
fn rewrite_transcode_index(
  index : Bytes,
  expected : @model.Digest,
  emitted : @model.Descriptor,
) -> Bytes raise @model.MoonOciError {
  guard @codec.parse_json_document(index, preserve_number_repr=true)
    is Object(fields) &&
    fields.get("manifests") is Some(Array(items)) else {
    raise @model.InvalidOci("transcode requires an OCI image index")
  }
  if fields.contains("subject") || fields.contains("artifactType") {
    raise @model.Unsupported("transcode requires a plain OCI image index")
  }
  if items.length() == 1 && expected == emitted.digest {
    return index
  }
  for item in items {
    if item is Object(raw) &&
      raw.get("digest") == Some(Json::string(expected.to_string())) {
      if expected != emitted.digest {
        replace_storage(
          raw,
          emitted.digest,
          emitted.media_type,
          emitted.size.to_int(),
        )
      }
      fields["manifests"] = Json::array([item])
      return @utf8.encode(Json::object(fields).stringify())
    }
  }
  raise @model.InvalidOci(
    "cannot find transcode source descriptor in raw index",
  )
}

///|
// External locations and embedded data refer to the prior stored bytes.
fn replace_storage(
  raw : Map[String, Json],
  digest : @model.Digest,
  media : String,
  size : Int32,
) -> Unit raise @model.MoonOciError {
  if raw.contains("urls") || raw.contains("data") {
    raise @model.Unsupported(
      "cannot rewrite a descriptor with inline data or external URLs",
    )
  }
  raw["digest"] = Json::string(digest.to_string())
  raw["mediaType"] = Json::string(media)
  raw["size"] = Json::number(size.to_double())
}
