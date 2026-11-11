///|
/// A complete rollout decision tied to one publication and policy document.
pub struct PromotionPlan {
  priv publication : @registry.PublishPlan
  priv bundle : @registry.BundlePublicationPlan?
  priv policy_digest : @model.Digest
  priv baseline_index : @model.Digest
  priv candidate_index : @model.Digest
}

///|
/// Prepare a reviewed Registry promotion. A candidate may have several
/// names for its root, but every name must refer to the same descriptor.
pub fn prepare(
  baseline : @layout.MemoryLayout,
  candidate : @layout.MemoryLayout,
  policy_document : Bytes,
  reference : String,
  origin : @registry.RegistryOrigin,
  repository : String,
  tag : String,
) -> PromotionPlan raise @model.MoonOciError {
  let policy = @rollout.decode_policy(policy_document)
  let catalog = @lifecycle.catalog(candidate, policy.candidate_index)
  let publication = @registry.plan_publication(
    catalog, reference, origin, repository, tag,
  )
  require_candidate_roots(candidate, catalog.resolve_reference(reference), [])
  review_promotion(
    baseline,
    candidate,
    policy_document,
    policy,
    publication,
    None,
  )
}

///|
/// Review every image platform and explicitly pin every advertised candidate
/// attachment. The baseline may contain known non-image artifacts.
pub fn prepare_bundle(
  baseline : @layout.MemoryLayout,
  candidate : @layout.MemoryLayout,
  policy_document : Bytes,
  reference : String,
  origin : @registry.RegistryOrigin,
  repository : String,
  tag : String,
  attachments : Array[@model.Digest],
) -> PromotionPlan raise @model.MoonOciError {
  let policy = @rollout.decode_policy(policy_document)
  let catalog = @lifecycle.catalog(candidate, policy.candidate_index)
  let bundle = @registry.plan_bundle_publication(
    catalog, reference, origin, repository, tag, attachments,
  )
  require_candidate_roots(
    candidate,
    catalog.resolve_reference(reference),
    bundle.attachments(),
  )
  review_promotion(
    baseline,
    candidate,
    policy_document,
    policy,
    bundle.publication(),
    Some(bundle),
  )
}

///|
fn require_candidate_roots(
  candidate : @layout.MemoryLayout,
  root : @model.Descriptor,
  attachments : Array[@registry.PublicationAttachment],
) -> Unit raise @model.MoonOciError {
  let objects : Map[String, @registry.PublishObject] = Map([])
  let advertised : Map[String, Bool] = Map([])
  for item in attachments {
    let object = item.object
    guard @codec.decode_manifest(object.data).config.media_type !=
      @model.media_type_config else {
      raise @model.InvalidArgument(
        "promotion attachment cannot also be an image",
      )
    }
    objects[object.digest.to_string()] = object
  }
  for descriptor in @codec.decode_index(candidate.index()).manifests {
    if descriptor.digest == root.digest &&
      descriptor.media_type == root.media_type &&
      descriptor.size == root.size &&
      descriptor.platform == root.platform {
      continue
    }
    let key = descriptor.digest.to_string()
    guard objects.get(key) is Some(object) &&
      descriptor.media_type == object.media_type &&
      descriptor.size == object.data.length().to_int64() &&
      descriptor.platform is None else {
      raise @model.InvalidArgument(
        "promotion candidate advertises a root outside the approved release",
      )
    }
    advertised[key] = true
  }
  if advertised.length() != attachments.length() {
    raise @model.InvalidArgument(
      "promotion attachment must be advertised in candidate index",
    )
  }
}

///|
fn review_promotion(
  baseline : @layout.MemoryLayout,
  candidate : @layout.MemoryLayout,
  policy_document : Bytes,
  policy : @rollout.RolloutPolicy,
  publication : @registry.PublishPlan,
  bundle : @registry.BundlePublicationPlan?,
) -> PromotionPlan raise @model.MoonOciError {
  for object in publication.manifests() {
    guard @codec.parse_json_document(object.data) is Object(fields) &&
      !fields.contains("subject") &&
      !fields.contains("artifactType") else {
      raise @model.Unsupported(
        "promotion requires plain image manifests and indexes",
      )
    }
  }
  let decision = @rollout.evaluate_rollout(
    baseline,
    candidate,
    policy,
    complete=true,
    allow_known_non_images=bundle is Some(_),
  )
  if !decision.allowed {
    raise @model.DigestMismatch(
      "complete rollout policy refused Registry promotion",
    )
  }
  {
    publication,
    bundle,
    policy_digest: @digest.sha256(policy_document),
    baseline_index: policy.baseline_index,
    candidate_index: policy.candidate_index,
  }
}

///|
pub fn PromotionPlan::publication(
  self : PromotionPlan,
) -> @registry.PublishPlan {
  self.publication
}

///|
pub fn PromotionPlan::bundle(
  self : PromotionPlan,
) -> @registry.BundlePublicationPlan? {
  self.bundle
}

///|
fn review_fields(plan : PromotionPlan) -> Map[String, Json] {
  let fields : Map[String, Json] = {
    "schema": "moonoci.promotion.v1",
    "policyDigest": Json::string(plan.policy_digest.to_string()),
    "baselineIndex": Json::string(plan.baseline_index.to_string()),
    "candidateIndex": Json::string(plan.candidate_index.to_string()),
    "root": Json::string(plan.publication.root().to_string()),
    "publicationPin": Json::string(plan.publication.pin().to_string()),
  }
  if plan.bundle is Some(bundle) {
    fields["bundlePin"] = Json::string(bundle.pin().to_string())
  }
  fields
}

///|
pub fn PromotionPlan::pin(self : PromotionPlan) -> @model.Digest {
  @digest.sha256(@utf8.encode(Json::object(review_fields(self)).stringify()))
}

///|
pub fn review_json(plan : PromotionPlan) -> String {
  let fields = review_fields(plan)
  fields["promotionPin"] = Json::string(plan.pin().to_string())
  Json::object(fields).stringify()
}
