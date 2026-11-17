///|
/// Change the storage encoding of a verified OCI layer without rewriting tar.
pub(all) struct LayerTranscode {
  media_type : String
  data : Bytes
  digest : @model.Digest
  diff_id : @model.Digest
}

///|
/// Verify both identities, then retain the exact uncompressed tar bytes.
pub fn transcode_layer_blob(
  descriptor : @model.Descriptor,
  data : Bytes,
  diff_id : @model.Digest,
  compression : @model.Compression,
  gzip_level~ : Int32 = 0,
) -> LayerTranscode raise @model.MoonOciError {
  validate_transcode_encoding(compression, gzip_level)
  if descriptor.size != data.length().to_int64() {
    raise @model.SizeMismatch("layer storage size does not match descriptor")
  }
  if @digest.sha256(data) != descriptor.digest {
    raise @model.DigestMismatch(
      "layer storage digest does not match descriptor",
    )
  }
  let tar = decode_layer_blob(descriptor.media_type, data)
  if @digest.sha256(tar) != diff_id {
    raise @model.DigestMismatch(
      "layer DiffID does not match the expected tar digest",
    )
  }
  ignore(archived_rootfs_transitions(@archive.read_layer_tar(tar)))
  let target_media = match compression {
    Uncompressed => @model.media_type_layer_tar
    Gzip => @model.media_type_layer_gzip
  }
  if target_media == descriptor.media_type {
    { media_type: target_media, data, digest: descriptor.digest, diff_id, }
  } else {
    let (media_type, data) = compress_layer(tar, compression, gzip_level~)
    { media_type, data, digest: @digest.sha256(data), diff_id, }
  }
}

///|
fn validate_transcode_encoding(
  compression : @model.Compression,
  gzip_level : Int32,
) -> Unit raise @model.MoonOciError {
  if gzip_level < 0 || gzip_level > 9 {
    raise @model.InvalidArgument("gzip level must be between 0 and 9")
  }
  if compression == Uncompressed && gzip_level != 0 {
    raise @model.InvalidArgument("nonzero gzip level requires gzip output")
  }
}
