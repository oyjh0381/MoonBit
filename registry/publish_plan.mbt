///|
pub(all) struct PublishObject {
  digest : @model.Digest
  media_type : String
  data : Bytes
}

///|
/// An immutable snapshot of the bytes selected for a destination tag.
pub struct PublishPlan {
  priv origin : RegistryOrigin
  priv repository : String
  priv tag : String
  priv mount_source : String?
  priv source_reference : String
  priv source_index : @model.Digest
  priv source_store : @model.Digest
  priv root : @model.Digest
  priv blobs : Array[PublishObject]
  priv manifests : Array[PublishObject]
}

///|
/// Resolve and capture the content before any registry traffic. Destination
/// tags are explicit and do not inherit a name from the source layout.
pub fn plan_publication(
  catalog : @lifecycle.ContentCatalog,
  source_reference : String,
  origin : RegistryOrigin,
  repository : String,
  tag : String,
) -> PublishPlan raise @model.MoonOciError {
  validate_repository(repository)
  validate_reference(tag)
  if tag.contains(":") {
    raise @model.InvalidArgument("registry publication needs an explicit tag")
  }
  let closure = catalog.upload_closure(source_reference)
  let layout = catalog.snapshot()
  fn load(
    descriptor : @model.Descriptor,
  ) -> PublishObject raise @model.MoonOciError {
    guard layout.get_blob(descriptor.digest) is Some(data) else {
      raise @model.InvalidOci(
        "catalog publication closure lacks verified bytes",
      )
    }
    { digest: descriptor.digest, media_type: descriptor.media_type, data, }
  }
  {
    origin,
    repository,
    tag,
    mount_source: None,
    source_reference,
    source_index: catalog.source_index(),
    source_store: catalog.store_pin(),
    root: closure.root.digest,
    blobs: closure.blobs.map(load),
    manifests: closure.manifests.map(load),
  }
}

///|
pub fn PublishPlan::origin(self : PublishPlan) -> RegistryOrigin {
  self.origin
}

///|
pub fn PublishPlan::repository(self : PublishPlan) -> String {
  self.repository
}

///|
pub fn PublishPlan::tag(self : PublishPlan) -> String {
  self.tag
}

///|
pub fn PublishPlan::mount_source(self : PublishPlan) -> String? {
  self.mount_source
}

///|
/// Allow cross-repository reuse from one explicitly reviewed repository.
pub fn PublishPlan::with_mount_source(
  self : PublishPlan,
  source : String,
) -> PublishPlan raise @model.MoonOciError {
  validate_mount_source(self.repository, source)
  { ..self, mount_source: Some(source), }
}

///|
pub fn PublishPlan::root(self : PublishPlan) -> @model.Digest {
  self.root
}

///|
pub fn PublishPlan::blobs(self : PublishPlan) -> Array[PublishObject] {
  self.blobs.copy()
}

///|
/// The final manifest is the root which will be published under the tag.
pub fn PublishPlan::manifests(self : PublishPlan) -> Array[PublishObject] {
  self.manifests.copy()
}

///|
fn describe_objects(objects : Array[PublishObject]) -> Json {
  Json::array(
    objects.map(item => {
      "digest": Json::string(item.digest.to_string()),
      "media_type": Json::string(item.media_type),
      "size": Json::string(item.data.length().to_string()),
    }),
  )
}

///|
fn publication_fields(plan : PublishPlan) -> Map[String, Json] {
  let fields : Map[String, Json] = {
    "schema": "moonoci.registry-publication.v1",
    "origin": Json::string(plan.origin.url()),
    "repository": Json::string(plan.repository),
    "tag": Json::string(plan.tag),
    "source_reference": Json::string(plan.source_reference),
    "source_index": Json::string(plan.source_index.to_string()),
    "source_store": Json::string(plan.source_store.to_string()),
    "root": Json::string(plan.root.to_string()),
    "blobs": describe_objects(plan.blobs),
    "manifests": describe_objects(plan.manifests),
  }
  if plan.mount_source is Some(source) {
    fields["mount_source"] = Json::string(source)
  }
  fields
}

///|
/// Unsigned identifier for the exact destination and reviewed source contents.
pub fn PublishPlan::pin(self : PublishPlan) -> @model.Digest {
  @digest.sha256(
    @utf8.encode(Json::object(publication_fields(self)).stringify()),
  )
}

///|
pub fn publication_json(plan : PublishPlan) -> String {
  let fields = publication_fields(plan)
  fields["plan_pin"] = Json::string(plan.pin().to_string())
  Json::object(fields).stringify()
}
