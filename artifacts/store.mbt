///|
pub(all) struct ArtifactPayload {
  media_type : String
  data : Bytes
  annotations : Array[@model.KeyValue]
}

///|
pub(all) struct ArtifactLimits {
  max_payloads : Int32
  max_payload_bytes : Int64
  max_total_bytes : Int64
  max_manifest_bytes : Int32
  max_config_bytes : Int32
}

///|
pub fn ArtifactLimits::default() -> ArtifactLimits {
  {
    max_payloads: 1024,
    max_payload_bytes: 67108864L,
    max_total_bytes: 268435456L,
    max_manifest_bytes: 4194304,
    max_config_bytes: 1048576,
  }
}

///|
pub(all) struct ArtifactBundle {
  layout : @layout.MemoryLayout
  descriptor : @model.Descriptor
}

///|
pub(all) struct ArtifactObservation {
  descriptor : @model.Descriptor
  manifest : ArtifactManifest
  payload_bytes : Int64
  subject_present : Bool
}

///|
pub fn ArtifactLimits::validate(
  limits : ArtifactLimits,
) -> Unit raise @model.MoonOciError {
  if limits.max_payloads < 1 ||
    limits.max_payloads > 100000 ||
    limits.max_payload_bytes < 1L ||
    limits.max_total_bytes < 1L ||
    limits.max_manifest_bytes < 1 ||
    limits.max_config_bytes < 1 {
    raise @model.InvalidArgument("invalid artifact resource limits")
  }
}

///|
pub fn inspect(
  source : @layout.MemoryLayout,
  descriptor : @model.Descriptor,
  limits~ : ArtifactLimits = ArtifactLimits::default(),
  require_subject~ : Bool = false,
) -> ArtifactObservation raise @model.MoonOciError {
  limits.validate()
  if descriptor.media_type != @model.media_type_manifest {
    raise @model.InvalidOci("artifact must use OCI image-manifest media type")
  }
  if descriptor.size > limits.max_manifest_bytes.to_int64() {
    raise @model.ResourceLimitExceeded("artifact manifest byte quota exceeded")
  }
  let raw = source.require_blob(descriptor)
  let manifest = decode_manifest(raw)
  if manifest.payloads.length() > limits.max_payloads ||
    manifest.config.size > limits.max_config_bytes.to_int64() {
    raise @model.ResourceLimitExceeded(
      "artifact config or payload count quota exceeded",
    )
  }
  let config = source.require_blob(manifest.config)
  if manifest.config.media_type == empty_media_type && config != b"{}" {
    raise @model.InvalidOci("empty artifact config must contain exactly {}")
  }
  let mut total = raw.length().to_int64() + config.length().to_int64()
  let mut payload_bytes = 0L
  for payload in manifest.payloads {
    if payload.size < 0L ||
      payload.size > limits.max_payload_bytes ||
      payload.size > limits.max_total_bytes - total {
      raise @model.ResourceLimitExceeded("artifact payload byte quota exceeded")
    }
    let data = source.require_blob(payload)
    payload_bytes += data.length().to_int64()
    total += data.length().to_int64()
  }
  if total > limits.max_total_bytes {
    raise @model.ResourceLimitExceeded("artifact total byte quota exceeded")
  }
  let subject_present = match manifest.subject {
    None => false
    Some(subject) =>
      match source.get_blob(subject.digest) {
        None => false
        Some(_) => {
          if subject.size > limits.max_manifest_bytes.to_int64() {
            raise @model.ResourceLimitExceeded(
              "local artifact subject metadata quota exceeded",
            )
          }
          ignore(source.require_blob(subject))
          true
        }
      }
  }
  if require_subject && !subject_present {
    raise @model.InvalidOci("artifact subject content is not locally available")
  }
  { descriptor, manifest, payload_bytes, subject_present, }
}

///|
/// Build an OCI artifact layout. A subject may refer to a separate content graph.
pub fn build(
  artifact_type : String,
  payloads : Array[ArtifactPayload],
  subject? : @model.Descriptor,
  annotations~ : Array[@model.KeyValue] = [],
  reference~ : String = "artifact",
  limits~ : ArtifactLimits = ArtifactLimits::default(),
) -> ArtifactBundle raise @model.MoonOciError {
  let source = @layout.MemoryLayout::new()
  source.set_index(
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests: [],
      annotations: [],
    }),
  )
  assemble(
    source, subject, artifact_type, payloads, annotations, reference, limits,
  )
}

///|
/// Add a subject-bound artifact to a fresh layout copy. Source is unchanged.
pub fn attach(
  source : @layout.MemoryLayout,
  subject : @model.Descriptor,
  artifact_type : String,
  payloads : Array[ArtifactPayload],
  annotations~ : Array[@model.KeyValue] = [],
  reference~ : String = "artifact",
  limits~ : ArtifactLimits = ArtifactLimits::default(),
) -> ArtifactBundle raise @model.MoonOciError {
  limits.validate()
  if subject.media_type != @model.media_type_manifest &&
    subject.media_type != @model.media_type_index {
    raise @model.InvalidArgument(
      "artifact subject must describe a manifest or index",
    )
  }
  if subject.size > limits.max_manifest_bytes.to_int64() {
    raise @model.ResourceLimitExceeded(
      "artifact subject metadata quota exceeded",
    )
  }
  // A layout root lives as index.json rather than a blob. Preserve the exact
  // pre-attachment index as content before binding the new artifact to it.
  if subject.media_type == @model.media_type_index &&
    subject.size == source.index().length().to_int64() &&
    @digest.sha256(source.index()) == subject.digest {
    let promoted = @layout.MemoryLayout::from_untrusted_parts(
      source.marker(),
      source.index(),
      source.blob_records().map(b => (b.descriptor(), b.data())),
    )
    ignore(promoted.put_blob(@model.media_type_index, source.index()))
    // Advertise the preserved subject descriptor so layout clients can resolve
    // its media type by digest rather than treating the blob as octet-stream.
    let original = @codec.decode_index(source.index())
    if !original.manifests.any(d => d.digest == subject.digest) {
      promoted.set_index(
        @codec.encode_index({
          ..original,
          manifests: original.manifests + [subject],
        }),
      )
    }
    return assemble(
      promoted,
      Some(subject),
      artifact_type,
      payloads,
      annotations,
      reference,
      limits,
    )
  }
  ignore(source.require_blob(subject))
  assemble(
    source,
    Some(subject),
    artifact_type,
    payloads,
    annotations,
    reference,
    limits,
  )
}

///|
fn assemble(
  source : @layout.MemoryLayout,
  subject : @model.Descriptor?,
  artifact_type : String,
  payloads : Array[ArtifactPayload],
  annotations : Array[@model.KeyValue],
  reference : String,
  limits : ArtifactLimits,
) -> ArtifactBundle raise @model.MoonOciError {
  limits.validate()
  validate_media_type(artifact_type)
  if reference.is_empty() || reference.contains_char('\u{0000}') {
    raise @model.InvalidArgument(
      "artifact reference must be nonempty without NUL",
    )
  }
  if payloads.length() > limits.max_payloads {
    raise @model.ResourceLimitExceeded("artifact payload count quota exceeded")
  }
  let mut bytes = 0L
  for payload in payloads {
    validate_media_type(payload.media_type)
    let size = payload.data.length().to_int64()
    if size > limits.max_payload_bytes || size > limits.max_total_bytes - bytes {
      raise @model.ResourceLimitExceeded("artifact payload byte quota exceeded")
    }
    bytes += size
  }
  @codec.validate_layout_marker(source.marker())
  let index = @codec.decode_index(source.index())
  if index.schema_version != 2 || index.media_type != @model.media_type_index {
    raise @model.InvalidOci("artifact store requires OCI index")
  }
  let layout = @layout.MemoryLayout::from_untrusted_parts(
    source.marker(),
    source.index(),
    source.blob_records().map(b => (b.descriptor(), b.data())),
  )
  let config = layout.put_blob(empty_media_type, b"{}")
  let layers = payloads.map(p => {
    layout.put_blob(p.media_type, p.data, annotations=p.annotations)
  })
  // Follow OCI's portable empty-artifact guidance rather than emitting an
  // empty layers array rejected by some artifact consumers.
  if layers.is_empty() {
    layers.push(config)
  }
  let manifest : ArtifactManifest = {
    artifact_type,
    config,
    payloads: layers,
    subject,
    annotations,
  }
  let descriptor = layout.put_blob(
    @model.media_type_manifest,
    encode_manifest(manifest),
    annotations=[{ key: @model.annotation_ref_name, value: reference, }],
  )
  ignore(inspect(layout, descriptor, limits~))
  let manifests = index.manifests.copy()
  if !manifests.any(d => d == descriptor) {
    manifests.push(descriptor)
  }
  layout.set_index(@codec.encode_index({ ..index, manifests, }))
  { layout, descriptor, }
}
