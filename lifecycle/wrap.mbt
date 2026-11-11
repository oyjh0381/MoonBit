///|
/// Advertise the exact current index bytes as one named release. Every child
/// descriptor and its metadata remains byte-for-byte intact.
pub fn ContentCatalog::wrap_index(
  self : ContentCatalog,
  reference : String,
) -> @layout.MemoryLayout raise @model.MoonOciError {
  if reference.is_empty() ||
    reference.length() > 255 ||
    reference.contains_char('\u{0000}') {
    raise @model.InvalidArgument("invalid named release reference")
  }
  let result = self.snapshot()
  let root = result.put_blob(@model.media_type_index, self.index, annotations=[
    { key: @model.annotation_ref_name, value: reference, },
  ])
  result.set_index(
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests: [root],
      annotations: [],
    }),
  )
  result
}
