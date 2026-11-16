///|
async fn transcode_image_command(args : Array[String]) -> Unit {
  if args.length() < 6 {
    raise @model.InvalidArgument(
      "usage: moonoci transcode-image INPUT MANIFEST_PIN none|gzip OUTPUT [--layers POSITIONS] [--dry-run|--expect-index DIGEST]",
    )
  }
  let mut positions : Array[Int32]? = None
  let mut expected_source_index : @model.Digest? = None
  let mut expected_index : @model.Digest? = None
  let mut dry_run = false
  let mut offset = 6
  while offset < args.length() {
    match args[offset] {
      "--layers" if offset + 1 < args.length() && positions is None => {
        offset += 1
        positions = Some(parse_transcode_positions(args[offset]))
      }
      "--expect-source-index" if offset + 1 < args.length() &&
        expected_source_index is None => {
        offset += 1
        expected_source_index = Some(@model.Digest::parse(args[offset]))
      }
      "--expect-index" if offset + 1 < args.length() && expected_index is None => {
        offset += 1
        expected_index = Some(@model.Digest::parse(args[offset]))
      }
      "--dry-run" if !dry_run => dry_run = true
      _ => raise @model.InvalidArgument("invalid or duplicate transcode option")
    }
    offset += 1
  }
  if dry_run && expected_index is Some(_) {
    raise @model.InvalidArgument(
      "dry-run and expected index are mutually exclusive",
    )
  }
  let expected = @model.Digest::parse(args[3])
  let compression : @model.Compression = match args[4] {
    "none" => Uncompressed
    "gzip" => Gzip
    _ =>
      raise @model.InvalidArgument("transcode compression must be none or gzip")
  }
  let source = @native.load_bounded_layout(args[2])
  let source_index = @digest.sha256(source.index())
  if expected_source_index is Some(pin) && pin != source_index {
    raise @model.DigestMismatch("transcode source index differs from its pin")
  }
  let result = @builder.transcode_image(
    source,
    expected,
    compression,
    positions?,
  )
  let index_pin = @digest.sha256(result.layout.index())
  if expected_index is Some(pin) && pin != index_pin {
    raise @model.DigestMismatch(
      "transcode output index differs from the preview pin",
    )
  }
  if !dry_run {
    @native.write_layout(args[5], result.layout)
  }
  let receipt : Json = {
    "schema": "moonoci.image-transcode.v1",
    "sourceIndex": Json::string(source_index.to_string()),
    "sourceManifest": Json::string(expected.to_string()),
    "resultManifest": Json::string(result.manifest.digest.to_string()),
    "resultIndex": Json::string(index_pin.to_string()),
    "written": Json::boolean(!dry_run),
    "convertedLayers": Json::number(result.converted_layers.to_double()),
    "sourceLayerBytes": Json::string(result.source_layer_bytes.to_string()),
    "resultLayerBytes": Json::string(result.result_layer_bytes.to_string()),
    "storageEncoding": Json::string(args[4]),
  }
  @stdio.stdout.write(receipt.stringify() + "\n")
}

///|
fn parse_transcode_positions(
  value : String,
) -> Array[Int32] raise @model.MoonOciError {
  let positions : Array[Int32] = []
  for item in value.split(",") {
    let token = item.to_owned()
    if token.is_empty() || !token.to_array().all(ch => ch >= '0' && ch <= '9') {
      raise @model.InvalidArgument(
        "transcode layer positions must be comma-separated decimal integers",
      )
    }
    positions.push(
      @string.parse_int(token) catch {
        _ =>
          raise @model.InvalidArgument(
            "transcode layer position exceeds integer range",
          )
      },
    )
  }
  positions
}
