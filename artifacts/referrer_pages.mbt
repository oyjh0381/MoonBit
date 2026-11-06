///|
pub(all) struct ReferrerAdvertisement {
  descriptor : @model.Descriptor
  artifact_type : String?
}

///|
pub(all) struct ReferrerPageVerification {
  valid : Bool
  checked : Int32
  findings : Array[StoreFinding]
}

///|
/// Parse a registry-style/referrers-tag index without losing artifactType.
/// A page is not a completeness statement; pagination belongs to the host.
pub fn decode_referrer_page(
  input : Bytes,
  max_entries~ : Int32 = 4096,
) -> Array[ReferrerAdvertisement] raise @model.MoonOciError {
  if max_entries < 1 || max_entries > 100000 {
    raise @model.InvalidArgument("invalid referrer page entry limit")
  }
  let index = @codec.decode_index(input)
  if index.schema_version != 2 || index.media_type != @model.media_type_index {
    raise @model.InvalidOci("referrer page must be an OCI index")
  }
  if index.manifests.length() > max_entries {
    raise @model.ResourceLimitExceeded("referrer page entry quota exceeded")
  }
  let items = match @codec.parse_json_document(input) {
    Object(fields) =>
      match fields.get("manifests") {
        Some(Array(items)) => items
        _ => raise @model.InvalidOci("missing referrer descriptors")
      }
    _ => raise @model.InvalidOci("invalid referrer page")
  }
  let seen : Map[String, Bool] = Map([])
  let result : Array[ReferrerAdvertisement] = []
  for i, descriptor in index.manifests {
    let key = descriptor.digest.to_string()
    if seen.contains(key) {
      raise @model.InvalidOci("duplicate advertised referrer")
    }
    seen[key] = true
    let kind = match items[i] {
      Object(fields) =>
        match fields.get("artifactType") {
          None => None
          Some(String(value)) => {
            validate_media_type(value)
            Some(value)
          }
          _ =>
            raise @model.InvalidOci("advertised artifactType must be a string")
        }
      _ => raise @model.InvalidOci("advertised descriptor must be an object")
    }
    result.push({ descriptor, artifact_type: kind, })
  }
  result
}

///|
/// Check advertisements against content-addressed local metadata. This does not
/// validate payload semantics/signatures or prove that a remote listing is full.
pub fn verify_referrer_page(
  source : @layout.MemoryLayout,
  subject : @model.Digest,
  advertisements : Array[ReferrerAdvertisement],
  artifact_type? : String,
) -> ReferrerPageVerification raise @model.MoonOciError {
  if advertisements.length() > 4096 {
    raise @model.ResourceLimitExceeded(
      "referrer verification page quota exceeded",
    )
  }
  if artifact_type is Some(value) {
    validate_media_type(value)
  }
  let actual = referrers(source, subject)
  let by_digest : Map[String, Referrer] = Map([])
  for item in actual.referrers {
    by_digest[item.descriptor.digest.to_string()] = item
  }
  let findings : Array[StoreFinding] = []
  let seen : Map[String, Bool] = Map([])
  for advertisement in advertisements {
    let descriptor = advertisement.descriptor
    let key = descriptor.digest.to_string()
    let add = fn(code : String, message : String) {
      findings.push({ code, digest: Some(key), message, })
    }
    if seen.contains(key) {
      add("duplicate-advertisement", "referrer occurs more than once in page")
      continue
    }
    seen[key] = true
    if artifact_type is Some(filter) {
      if advertisement.artifact_type != Some(filter) {
        add(
          "filter-mismatch", "advertisement does not match requested artifact type",
        )
      }
    }
    match by_digest.get(key) {
      None =>
        add(
          "subject-mismatch", "advertised metadata does not refer to the requested subject",
        )
      Some(found) => {
        if descriptor.media_type != found.descriptor.media_type ||
          descriptor.size != found.descriptor.size {
          add(
            "descriptor-mismatch", "advertised media type or size differs from actual content",
          )
        }
        if advertisement.artifact_type != found.artifact_type {
          add(
            "artifact-type-mismatch", "advertised type differs from manifest metadata",
          )
        }
        if annotations_json(descriptor.annotations) !=
          annotations_json(found.descriptor.annotations) {
          add(
            "annotation-mismatch", "advertisement does not carry the manifest annotations",
          )
        }
      }
    }
  }
  { valid: findings.is_empty(), checked: advertisements.length(), findings, }
}
