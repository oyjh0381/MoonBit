///|
/// A complete rollout decision tied to one publication and policy document.
pub struct PromotionPlan {
  priv publication : @registry.PublishPlan
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
  let root = catalog.resolve_reference(reference)
  let index = @codec.decode_index(candidate.index())
  for descriptor in index.manifests {
    if descriptor.digest != root.digest ||
      descriptor.media_type != root.media_type ||
      descriptor.size != root.size ||
      descriptor.platform != root.platform {
      raise @model.InvalidArgument(
        "promotion candidate must advertise one immutable release root",
      )
    }
  }
  let publication = @registry.plan_publication(
    catalog, reference, origin, repository, tag,
  )
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
  )
  if !decision.allowed {
    raise @model.DigestMismatch(
      "complete rollout policy refused Registry promotion",
    )
  }
  {
    publication,
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
fn review_fields(plan : PromotionPlan) -> Map[String, Json] {
  {
    "schema": "moonoci.promotion.v1",
    "policyDigest": Json::string(plan.policy_digest.to_string()),
    "baselineIndex": Json::string(plan.baseline_index.to_string()),
    "candidateIndex": Json::string(plan.candidate_index.to_string()),
    "root": Json::string(plan.publication.root().to_string()),
    "publicationPin": Json::string(plan.publication.pin().to_string()),
  }
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
