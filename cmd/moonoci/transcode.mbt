///|
async fn transcode_image_command(args : Array[String]) -> Unit {
  require_arity(
    args, 6, "usage: moonoci transcode-image INPUT MANIFEST_PIN none|gzip OUTPUT",
  )
  let expected = @model.Digest::parse(args[3])
  let compression : @model.Compression = match args[4] {
    "none" => Uncompressed
    "gzip" => Gzip
    _ =>
      raise @model.InvalidArgument("transcode compression must be none or gzip")
  }
  let source = @native.load_bounded_layout(args[2])
  let result = @builder.transcode_image(source, expected, compression)
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
