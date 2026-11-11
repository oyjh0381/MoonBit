///|
pub(all) struct PublicationAttachment {
  object : PublishObject
  artifact_type : String
}

///|
/// A named root and an explicit set of its immediate OCI referrers.
pub struct BundlePublicationPlan {
  priv publication : PublishPlan
  priv attachments : Array[PublicationAttachment]
}

///|
/// Resolve each approved attachment digest and check its exact subject,
/// artifact type and payload bytes before building a bundle upload plan.
pub fn plan_bundle_publication(
  catalog : @lifecycle.ContentCatalog,
  source_reference : String,
  origin : RegistryOrigin,
  repository : String,
  tag : String,
  attachments : Array[@model.Digest],
) -> BundlePublicationPlan raise @model.MoonOciError {
  let selection = ReferrerSelection::new(attachments)
  let base = plan_publication(
    catalog, source_reference, origin, repository, tag,
  )
  let root = base.manifests[base.manifests.length() - 1]
  let source = catalog.snapshot()
  let all_blobs = base.blobs.copy()
  let blob_seen : Map[String, Bool] = Map([])
  for object in all_blobs {
    blob_seen[object.digest.to_string()] = true
  }
  let verified : Array[PublicationAttachment] = []
  for digest in selection.pins {
    guard source.get_blob(digest) is Some(data) else {
      raise @model.InvalidArgument("bundle publication attachment is absent")
    }
    let descriptor : @model.Descriptor = {
      digest,
      media_type: @model.media_type_manifest,
      size: data.length().to_int64(),
      annotations: [],
      platform: None,
    }
    let artifact = @artifacts.inspect(source, descriptor, require_subject=true).manifest
    guard artifact.subject is Some(subject) &&
      subject.digest == root.digest &&
      subject.media_type == root.media_type &&
      subject.size == root.data.length().to_int64() else {
      raise @model.DigestMismatch(
        "attachment subject differs from the named publication root",
      )
    }
    for payload in [artifact.config] + artifact.payloads {
      let key = payload.digest.to_string()
      if !blob_seen.contains(key) {
        blob_seen[key] = true
        all_blobs.push({
          digest: payload.digest,
          media_type: payload.media_type,
          data: source.get_blob(payload.digest).unwrap(),
        })
      }
    }
    verified.push({
      object: { digest, media_type: descriptor.media_type, data, },
      artifact_type: artifact.artifact_type,
    })
  }
  { publication: { ..base, blobs: all_blobs, }, attachments: verified, }
}

///|
pub fn BundlePublicationPlan::publication(
  self : BundlePublicationPlan,
) -> PublishPlan {
  self.publication
}

///|
pub fn BundlePublicationPlan::with_mount_source(
  self : BundlePublicationPlan,
  source : String,
) -> BundlePublicationPlan raise @model.MoonOciError {
  { ..self, publication: self.publication.with_mount_source(source), }
}

///|
pub fn BundlePublicationPlan::attachments(
  self : BundlePublicationPlan,
) -> Array[PublicationAttachment] {
  self.attachments.copy()
}

///|
fn bundle_publication_fields(plan : BundlePublicationPlan) -> Map[String, Json] {
  {
    "schema": "moonoci.registry-bundle-publication.v1",
    "publicationPin": Json::string(plan.publication.pin().to_string()),
    "root": Json::string(plan.publication.root().to_string()),
    "attachments": Json::array(
      plan.attachments.map(attachment => {
        "digest": Json::string(attachment.object.digest.to_string()),
        "size": Json::string(attachment.object.data.length().to_string()),
        "artifactType": Json::string(attachment.artifact_type),
      }),
    ),
  }
}

///|
pub fn BundlePublicationPlan::pin(
  self : BundlePublicationPlan,
) -> @model.Digest {
  @digest.sha256(
    @utf8.encode(Json::object(bundle_publication_fields(self)).stringify()),
  )
}

///|
/// Export the approved content identifiers independently of the push destination.
pub fn BundlePublicationPlan::referrer_lock(
  self : BundlePublicationPlan,
) -> ReferrerLock {
  let root = self.publication.root
  {
    root,
    subject: root,
    approved: {
      pins: self.attachments.map(item => item.object.digest),
      exact_listing: false,
    },
  }
}

///|
pub fn bundle_publication_value(plan : BundlePublicationPlan) -> Json {
  let fields = bundle_publication_fields(plan)
  fields["bundlePin"] = Json::string(plan.pin().to_string())
  fields["publication"] = Json::object(publication_fields(plan.publication))
  let lock = plan.referrer_lock()
  let document = lock.encode()
  fields["referrerLock"] = {
    "pin": Json::string(@digest.sha256(document).to_string()),
    "document": Json::string(@utf8.decode_lossy(document)),
  }
  Json::object(fields)
}

///|
pub fn bundle_publication_json(plan : BundlePublicationPlan) -> String {
  bundle_publication_value(plan).stringify()
}
