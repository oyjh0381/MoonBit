///|
/// Export only the chosen artifact's manifest/config/payload closure. subject
/// remains a weak external reference; it is deliberately not recursively copied.
pub fn export_artifact(
  source : @layout.MemoryLayout,
  descriptor : @model.Descriptor,
  limits~ : ArtifactLimits = ArtifactLimits::default(),
) -> @layout.MemoryLayout raise @model.MoonOciError {
  let observed = inspect(source, descriptor, limits~)
  let result = @layout.MemoryLayout::new()
  let needed = [descriptor, observed.manifest.config]
  needed.append(observed.manifest.payloads)
  for item in needed {
    ignore(result.put_blob(item.media_type, source.require_blob(item)))
  }
  result.set_index(
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests: [descriptor],
      annotations: [],
    }),
  )
  result
}

///|
/// Return a verified payload by numeric position; annotations never choose paths.
pub fn payload_bytes(
  source : @layout.MemoryLayout,
  descriptor : @model.Descriptor,
  index : Int32,
  limits~ : ArtifactLimits = ArtifactLimits::default(),
) -> Bytes raise @model.MoonOciError {
  let observed = inspect(source, descriptor, limits~)
  if index < 0 || index >= observed.manifest.payloads.length() {
    raise @model.InvalidArgument("artifact payload index out of range")
  }
  source.require_blob(observed.manifest.payloads[index])
}

///|
pub fn observation_json(observed : ArtifactObservation) -> String {
  let payloads : Array[Json] = observed.manifest.payloads.map(payload => {
    "media_type": Json::string(payload.media_type),
    "digest": Json::string(payload.digest.to_string()),
    "bytes": Json::string(payload.size.to_string()),
  })
  let result : Json = {
    "schema": "moonoci.artifact.v1",
    "digest": Json::string(observed.descriptor.digest.to_string()),
    "artifact_type": Json::string(observed.manifest.artifact_type),
    "subject": match observed.manifest.subject {
      Some(subject) => Json::string(subject.digest.to_string())
      None => Json::null()
    },
    "subject_present": Json::boolean(observed.subject_present),
    "payload_bytes": Json::string(observed.payload_bytes.to_string()),
    "payloads": Json::array(payloads),
  }
  result.stringify()
}
