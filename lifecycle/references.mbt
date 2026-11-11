///|
/// Resolve a name attached to a root descriptor in the verified layout.
/// Repeated advertisements may differ in annotations, but must agree on
/// content identity and the optional platform.
pub fn ContentCatalog::resolve_reference(
  self : ContentCatalog,
  name : String,
) -> @model.Descriptor raise @model.MoonOciError {
  self.resolve_references([name])[0]
}

///|
/// Build a reviewable copy plan from root names. Names that refer to the same
/// immutable manifest share one content closure. All original aliases of
/// the retained digest remain advertised, as in digest-based retention.
pub fn ContentCatalog::retain_references(
  self : ContentCatalog,
  names : Array[String],
  policy~ : RetentionPolicy = RetentionPolicy::default(),
) -> RetentionPlan raise @model.MoonOciError {
  if names.is_empty() || names.length() > self.root_values.length() {
    raise @model.InvalidArgument(
      "reference retention needs a nonempty bounded selection",
    )
  }
  let seen : Map[String, Bool] = Map([])
  let roots : Array[@model.Digest] = []
  for descriptor in self.resolve_references(names) {
    let digest = descriptor.digest.to_string()
    if !seen.contains(digest) {
      seen[digest] = true
      roots.push(descriptor.digest)
    }
  }
  self.retain(roots, policy~)
}

///|
fn ContentCatalog::resolve_references(
  self : ContentCatalog,
  names : Array[String],
) -> Array[@model.Descriptor] raise @model.MoonOciError {
  let requested : Map[String, @model.Descriptor?] = Map([])
  for name in names {
    if name == "" || requested.contains(name) {
      raise @model.InvalidArgument("empty or repeated OCI layout reference")
    }
    requested[name] = None
  }
  for value in self.root_values {
    let descriptor = @codec.decode_descriptor(value)
    for annotation in descriptor.annotations {
      if annotation.key == @model.annotation_ref_name {
        let name = annotation.value
        match requested.get(name) {
          Some(Some(previous)) =>
            if !same_reference_target(previous, descriptor) {
              raise @model.InvalidOci("ambiguous OCI layout reference: " + name)
            }
          Some(None) => requested[name] = Some(descriptor)
          None => ()
        }
      }
    }
  }
  names.map(name => {
    match requested[name] {
      Some(descriptor) => descriptor
      None =>
        raise @model.InvalidArgument("unknown OCI layout reference: " + name)
    }
  })
}

///|
fn same_reference_target(a : @model.Descriptor, b : @model.Descriptor) -> Bool {
  a.digest == b.digest &&
  a.media_type == b.media_type &&
  a.size == b.size &&
  a.platform == b.platform
}
