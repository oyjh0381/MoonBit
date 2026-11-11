///|
/// Verify that a completed Registry listing advertises every approved
/// attachment with its exact digest, size, media type and artifact type.
pub fn verify_bundle_advertisements(
  plan : BundlePublicationPlan,
  entries : Array[@artifacts.ReferrerAdvertisement],
) -> Unit raise @model.MoonOciError {
  let expected : Map[String, PublicationAttachment] = Map([])
  for item in plan.attachments {
    expected[item.object.digest.to_string()] = item
  }
  let found : Map[String, Bool] = Map([])
  for entry in entries {
    let key = entry.descriptor.digest.to_string()
    if expected.get(key) is Some(item) {
      if entry.descriptor.size != item.object.data.length().to_int64() ||
        entry.descriptor.media_type != item.object.media_type ||
        entry.artifact_type != Some(item.artifact_type) {
        raise @model.InvalidOci(
          "Registry advertises incompatible metadata for a pinned attachment",
        )
      }
      found[key] = true
    }
  }
  if found.length() != expected.length() {
    raise @model.InvalidOci("Registry listing omits an approved attachment")
  }
}

///|
/// Acknowledgement that an OCI 1.1 server processed the exact subject on PUT.
pub fn check_publication_subject(
  headers : Array[@model.KeyValue],
  subject : @model.Digest,
) -> Unit raise @model.MoonOciError {
  guard single_header(headers, "oci-subject") is Some(value) else {
    raise @model.Unsupported(
      "Registry did not acknowledge OCI 1.1 referrer publication",
    )
  }
  if @model.Digest::parse(value) != subject {
    raise @model.DigestMismatch(
      "Registry acknowledged a different attachment subject",
    )
  }
}
