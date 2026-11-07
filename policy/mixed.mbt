///|
pub(all) struct MixedReleaseDecision {
  allowed : Bool
  source_index : @model.Digest
  images : PolicyDecision
  store : @artifacts.StoreVerification
}

///|
/// Validate a whole supported mixed store before projecting all image branches
/// for runtime/configuration policy. Unknown branches and artifact-only stores
/// cannot silently pass. Does not change source topology or subjects.
pub fn evaluate_mixed(
  source : @layout.MemoryLayout,
  policy~ : ReleasePolicy = ReleasePolicy::recommended(),
  graph_limits~ : @graph.WalkLimits = @graph.WalkLimits::default(),
  max_total_payload_bytes~ : Int64 = 536870912L,
) -> MixedReleaseDecision raise @model.MoonOciError {
  policy.validate()
  let store = @artifacts.verify_store(
    source,
    graph_limits~,
    max_total_payload_bytes~,
  )
  let blocked : PolicyDecision = {
    allowed: false,
    findings: [
      {
        code: "invalid-store",
        path: "index.json",
        message: "mixed store is invalid or outside the supported profile",
      },
    ],
    manifests_checked: 0,
    reachable_bytes: 0L,
  }
  let images = if !store.valid || !store.complete {
    blocked
  } else {
    try {
      let projected = @graph.flatten_images(
        source,
        limits=graph_limits,
        allow_skipped=true,
      )
      evaluate(projected, policy~)
    } catch {
      error =>
        {
          ..blocked,
          findings: [
            {
              code: "image-projection-failed",
              path: "index.json",
              message: error.message(),
            },
          ],
        }
    }
  }
  {
    allowed: store.valid && store.complete && images.allowed,
    source_index: @digest.sha256(source.index()),
    images,
    store,
  }
}

///|
pub fn mixed_release_json(
  decision : MixedReleaseDecision,
) -> String raise @model.MoonOciError {
  let report : Json = {
    "schema": Json::string("moonoci.mixed-release-policy.v1"),
    "allowed": Json::boolean(decision.allowed),
    "source_index": Json::string(decision.source_index.to_string()),
    "images": @codec.parse_json_document(
      @utf8.encode(render_json(decision.images)),
    ),
    "store": @codec.parse_json_document(
      @utf8.encode(@artifacts.verification_json(decision.store)),
    ),
  }
  report.stringify()
}
