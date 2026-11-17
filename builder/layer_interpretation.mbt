///|
/// Validated understanding of one supported Layer Blob.
priv struct LayerInterpretation {
  uncompressed : Bytes
  entries : Array[@archive.TarEntry]
}

///|
fn LayerInterpretation::diff_id(self : LayerInterpretation) -> @model.Digest {
  @digest.sha256(self.uncompressed)
}

///|
fn interpret_layer_blob(
  media_type : String,
  data : Bytes,
) -> LayerInterpretation raise @model.MoonOciError {
  let uncompressed = decode_layer_blob(media_type, data)
  let entries = @archive.read_layer_tar(uncompressed)
  { uncompressed, entries, }
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
  decode_gzip_layer(data, 512 * 1024 * 1024)
}

///|
fn decode_gzip_layer(
  data : Bytes,
  max_size : Int32,
) -> Bytes raise @model.MoonOciError {
  let uncompressed = @fzip.gunzip_sync(
    FixedArray::makei(data.length(), i => data[i]),
    opts={
      out: None,
      dictionary: None,
      max_output_size: max_size,
      max_input_size: data.length(),
      verify_checksum: true,
    },
  ) catch {
    _ => raise @model.InvalidTar("cannot decompress gzip layer")
  }
  let uncompressed = Bytes::from_array(uncompressed)
  if exceeds_gzip_layer_ratio(data.length(), uncompressed.length()) {
    raise @model.ResourceLimitExceeded(
      "gzip layer exceeds 200:1 expansion ratio",
    )
  }
  uncompressed
}

///|
fn exceeds_gzip_layer_ratio(compressed : Int32, decoded : Int32) -> Bool {
  compressed > 0 && decoded.to_int64() > compressed.to_int64() * 200L
}
