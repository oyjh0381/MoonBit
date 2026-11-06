///|
pub(all) struct Referrer {
  descriptor : @model.Descriptor
  artifact_type : String?
  subject : @model.Descriptor
}

///|
pub(all) struct ReferrerDiscovery {
  subject : @model.Digest
  referrers : Array[Referrer]
  unrecognized : Array[@graph.SkippedDescriptor]
  complete : Bool
}

///|
/// Discover advertised manifest/index subjects through a bounded local index
/// tree. This verifies referenced metadata, not payload content or signatures.
pub fn referrers(
  source : @layout.MemoryLayout,
  subject : @model.Digest,
  artifact_type? : String,
  limits~ : @graph.WalkLimits = @graph.WalkLimits::default(),
) -> ReferrerDiscovery raise @model.MoonOciError {
  if artifact_type is Some(value) {
    validate_media_type(value)
  }
  let walk = @graph.walk_indexes(source, limits~)
  let candidates = walk.images.map(image => image.descriptor)
  candidates.append(walk.indexes.map(index => index.descriptor))
  candidates.append(
    walk.skipped
    .filter(item => item.reason == "non-image-config")
    .map(item => item.descriptor),
  )
  let seen : Map[String, Bool] = Map([])
  let found : Array[Referrer] = []
  for descriptor in candidates {
    let key = descriptor.digest.to_string()
    if seen.contains(key) {
      continue
    }
    seen[key] = true
    let raw = source.require_blob(descriptor)
    let fields = match @codec.parse_json_document(raw) {
      Object(values) => values
      _ => raise @model.InvalidOci("referrer metadata must be an object")
    }
    let declared_subject = match fields.get("subject") {
      Some(value) => Some(@codec.decode_descriptor(value))
      None => None
    }
    if declared_subject is Some(link) {
      if link.digest != subject {
        continue
      }
      let declared_type = match fields.get("artifactType") {
        Some(String(value)) if !value.is_empty() => {
          validate_media_type(value)
          Some(value)
        }
        None | Some(String(_)) => None
        _ => raise @model.InvalidOci("artifactType must be a string")
      }
      let (annotations, effective_type) = if descriptor.media_type ==
        @model.media_type_manifest {
        let manifest = @codec.decode_manifest(raw)
        (
          manifest.annotations,
          Some(declared_type.unwrap_or(manifest.config.media_type)),
        )
      } else {
        (@codec.decode_index(raw).annotations, declared_type)
      }
      if artifact_type is Some(filter) {
        if effective_type != Some(filter) {
          continue
        }
      }
      found.push({
        descriptor: { ..descriptor, annotations, platform: None, },
        artifact_type: effective_type,
        subject: link,
      })
    }
  }
  found.sort_by((a, b) => {
    a.descriptor.digest.to_string().compare(b.descriptor.digest.to_string())
  })
  let unrecognized = walk.skipped.filter(item => {
    item.reason == "unknown-media-type"
  })
  {
    subject,
    referrers: found,
    unrecognized,
    complete: unrecognized.is_empty(),
  }
}

///|
/// OCI-style referrers index body for discovered matches, including artifactType
/// and manifest annotations. Completeness is available separately in discovery.
pub fn referrers_json(
  discovery : ReferrerDiscovery,
) -> String raise @model.MoonOciError {
  let manifests = discovery.referrers.map(item => {
    let descriptor = @codec.encode_descriptor(item.descriptor)
    match item.artifact_type {
      None => descriptor
      Some(value) =>
        descriptor[0:descriptor.length() - 1].to_owned() +
        ",\"artifactType\":" +
        quoted(value) +
        "}"
    }
  })
  "{\"schemaVersion\":2,\"mediaType\":" +
  quoted(@model.media_type_index) +
  ",\"manifests\":[" +
  manifests.join(",") +
  "]}"
}
