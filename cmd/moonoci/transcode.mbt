///|
async fn transcode_image_command(args : Array[String]) -> Unit {
  let positions = if args.length() == 8 && args[6] == "--layers" {
    let selected : Array[Int32] = []
    for item in args[7].split(",") {
      let token = item.to_owned()
      if token.is_empty() || !token.to_array().all(ch => ch >= '0' && ch <= '9') {
        raise @model.InvalidArgument(
          "transcode layer positions must be comma-separated decimal integers",
        )
      }
      let position = @string.parse_int(token) catch {
        _ =>
          raise @model.InvalidArgument(
            "transcode layer position exceeds integer range",
          )
      }
      selected.push(position)
    }
    Some(selected)
  } else {
    require_arity(
      args, 6, "usage: moonoci transcode-image INPUT MANIFEST_PIN none|gzip OUTPUT [--layers POSITIONS]",
    )
    None
  }
  let expected = @model.Digest::parse(args[3])
  let compression : @model.Compression = match args[4] {
    "none" => Uncompressed
    "gzip" => Gzip
    _ =>
      raise @model.InvalidArgument("transcode compression must be none or gzip")
  }
  let source = @native.load_bounded_layout(args[2])
  let result = @builder.transcode_image(
    source,
    expected,
    compression,
    positions?,
  )
  @native.write_layout(args[5], result.layout)
  let receipt : Json = {
    "schema": "moonoci.image-transcode.v1",
    "sourceManifest": Json::string(expected.to_string()),
    "resultManifest": Json::string(result.manifest.digest.to_string()),
    "resultIndex": Json::string(
      @digest.sha256(result.layout.index()).to_string(),
    ),
    "convertedLayers": Json::number(result.converted_layers.to_double()),
    "storageEncoding": Json::string(args[4]),
  }
  @stdio.stdout.write(receipt.stringify() + "\n")
}
