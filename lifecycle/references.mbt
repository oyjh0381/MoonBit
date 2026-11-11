///|
/// Resolve a name attached to a root descriptor in the verified layout.
/// Repeated advertisements may differ in annotations, but must agree on
/// content identity and the optional platform.
pub fn ContentCatalog::resolve_reference(
  self : ContentCatalog,
  name : String,
) -> @model.Descriptor raise @model.MoonOciError {
  if name == "" {
    raise @model.InvalidArgument("empty OCI layout reference")
  }
  let mut found : @model.Descriptor? = None
  for value in self.root_values {
    let descriptor = @codec.decode_descriptor(value)
    if descriptor.annotations.any(annotation => {
        annotation.key == @model.annotation_ref_name && annotation.value == name
      }) {
      match found {
        Some(previous) =>
          if previous.digest != descriptor.digest ||
            previous.media_type != descriptor.media_type ||
            previous.size != descriptor.size ||
            previous.platform != descriptor.platform {
            raise @model.InvalidOci("ambiguous OCI layout reference: " + name)
          }
        None => found = Some(descriptor)
      }
    }
  }
  match found {
    Some(descriptor) => descriptor
    None =>
      raise @model.InvalidArgument("unknown OCI layout reference: " + name)
  }
}
