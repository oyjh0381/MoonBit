///|
/// Publishable result of a verified single-platform storage conversion.
pub(all) struct ImageTranscode {
  layout : @layout.MemoryLayout
  manifest : @model.Descriptor
  converted_layers : Int32
}

///|
/// Derive a standalone selected image whose config and uncompressed layers
/// are byte-identical to the source. The supplied manifest pin selects the image.
pub fn transcode_image(
  source : @layout.MemoryLayout,
  expected : @model.Digest,
  compression : @model.Compression,
) -> ImageTranscode raise @model.MoonOciError {
  let index = @codec.decode_index(source.index())
  let matches = index.manifests.filter(item => item.digest == expected)
  guard matches is [descriptor] else {
    raise @model.InvalidArgument("transcode requires one exact index member")
  }
  let manifest = require_root_manifest(source, descriptor)
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
  for index, layer in manifest.layers {
    let data = source.require_blob(layer)
    let converted = transcode_layer_blob(
      layer,
      data,
      config.diff_ids[index],
      compression,
    )
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
    ignore(result.put_blob(converted.media_type, converted.data))
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
  result.set_index(
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests: [emitted],
      annotations: [],
    }),
  )
  if !verify_memory(result).is_valid() {
    raise @model.InvalidOci("derived image failed verification")
  }
  { layout: result, manifest: emitted, converted_layers, }
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
      "cannot rewrite layer with inline data or external URLs",
    )
  }
  raw["digest"] = Json::string(digest.to_string())
  raw["mediaType"] = Json::string(media)
  raw["size"] = Json::number(size.to_double())
}
