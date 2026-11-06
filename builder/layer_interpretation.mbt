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
  let entries = @archive.read_tar(uncompressed)
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
  let max_size = 512 * 1024 * 1024
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
  if data.length() > 0 &&
    uncompressed.length().to_int64() > data.length().to_int64() * 200L {
    raise @model.ResourceLimitExceeded(
      "gzip layer exceeds 200:1 expansion ratio",
    )
  }
  uncompressed
}
