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
) -> LayerTranscode raise @model.MoonOciError {
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
    let (media_type, data) = compress_layer(tar, compression)
    { media_type, data, digest: @digest.sha256(data), diff_id, }
  }
}
