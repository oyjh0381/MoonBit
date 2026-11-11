///|
pub(all) struct PlatformApproval {
  platform : @model.Platform
  approval : @review.UpgradeApproval
}

///|
pub(all) struct RolloutPolicy {
  baseline_index : @model.Digest
  candidate_index : @model.Digest
  required : Array[@model.Platform]
  approvals : Array[PlatformApproval]
  allow_new_platforms : Bool
}

///|
pub(all) struct PlatformDecision {
  pair : PlatformPair
  allowed : Bool
  upgrade : @review.UpgradeDecision?
}

///|
pub(all) struct RolloutDecision {
  comparison : ReleaseComparison
  platforms : Array[PlatformDecision]
  allowed : Bool
}

///|
fn image_descriptors(walk : @graph.IndexWalk) -> Map[String, @model.Descriptor] {
  let result : Map[String, @model.Descriptor] = Map([])
  for leaf in walk.images {
    result[leaf.descriptor.digest.to_string()] = leaf.descriptor
  }
  result
}

///|
/// Reuse the established flat-image verification and upgrade APIs with a view
/// of just the selected branch. Other roots are never reinterpreted as layers.
fn branch_layout(
  source : @layout.MemoryLayout,
  descriptor : @model.Descriptor,
) -> @layout.MemoryLayout raise @model.MoonOciError {
  let manifest = @codec.decode_manifest(source.require_blob(descriptor))
  let members = [descriptor, manifest.config] + manifest.layers
  let records : Array[(@model.Descriptor, Bytes)] = []
  let seen : Map[String, Bool] = Map([])
  for item in members {
    let key = item.digest.to_string()
    if !seen.contains(key) {
      guard source.get_blob(item.digest) is Some(bytes) else {
        raise @model.InvalidOci("selected rollout branch lacks content: " + key)
      }
      seen[key] = true
      records.push((item, bytes))
    }
  }
  let index = @codec.encode_index({
    schema_version: 2,
    media_type: @model.media_type_index,
    manifests: [descriptor],
    annotations: [],
  })
  @layout.MemoryLayout::from_untrusted_parts(source.marker(), index, records)
}

///|
/// Evaluate exact platform matches and explicit per-manifest approvals.
/// Unknown media block the decision. Known non-image artifacts are outside
/// this image rollout policy. Complete coverage excludes them unless the
/// caller handles them separately and explicitly allows known non-images.
pub fn evaluate_rollout(
  baseline : @layout.MemoryLayout,
  candidate : @layout.MemoryLayout,
  policy : RolloutPolicy,
  limits~ : @graph.WalkLimits = @graph.WalkLimits::default(),
  complete~ : Bool = false,
  allow_known_non_images~ : Bool = false,
) -> RolloutDecision raise @model.MoonOciError {
  if policy.approvals.length() > policy.required.length() {
    raise @model.InvalidArgument("too many rollout approvals")
  }
  let approvals : Map[String, @review.UpgradeApproval] = Map([])
  let required = policy.required.map(platform_key)
  for item in policy.approvals {
    let key = platform_key(item.platform)
    if !required.contains(key) {
      raise @model.InvalidArgument(
        "rollout approval names an unrequested platform",
      )
    }
    if approvals.contains(key) {
      raise @model.InvalidArgument("duplicate rollout platform approval")
    }
    approvals[key] = item.approval
  }
  let old_walk = @graph.walk_pinned(baseline, policy.baseline_index, limits~)
  let new_walk = @graph.walk_pinned(candidate, policy.candidate_index, limits~)
  let comparison = pair_coverage(
    coverage_from_walk(old_walk, policy.baseline_index, policy.required),
    coverage_from_walk(new_walk, policy.candidate_index, policy.required),
  )
  let old_descriptors = image_descriptors(old_walk)
  let new_descriptors = image_descriptors(new_walk)
  let complete_coverage = comparison.baseline_omitted.is_empty() &&
    comparison.candidate_omitted.is_empty() &&
    (
      allow_known_non_images ||
      (
        comparison.baseline_non_images == 0 &&
        comparison.candidate_non_images == 0
      )
    )
  let platforms = comparison.platforms.map(pair => {
    let approval = approvals.get(platform_key(pair.platform))
    if approval is Some(_) && !(pair.transition is Updated) {
      raise @model.InvalidArgument(
        "rollout approval must target an updated platform",
      )
    }
    match (pair.baseline, pair.candidate) {
      (Unique(old), Unique(next)) => {
        let before = old_descriptors[old.to_string()]
        let after = new_descriptors[next.to_string()]
        let accepted = approval.unwrap_or({
          expected_base: old,
          expected_target: next,
          approved_paths: [],
          approved_fields: [],
          allow_additions: false,
        })
        let upgrade = @review.evaluate_upgrade(
          branch_layout(baseline, before),
          before,
          branch_layout(candidate, after),
          after,
          accepted,
        )
        { pair, allowed: upgrade.allowed, upgrade: Some(upgrade), }
      }
      (Missing, Unique(next)) => {
        let descriptor = new_descriptors[next.to_string()]
        if !@builder.verify_memory(branch_layout(candidate, descriptor)).is_valid() {
          raise @model.InvalidOci(
            "introduced rollout image fails filesystem verification",
          )
        }
        { pair, allowed: policy.allow_new_platforms, upgrade: None, }
      }
      _ => { pair, allowed: false, upgrade: None, }
    }
  })
  {
    comparison,
    platforms,
    allowed: comparison.baseline_unknown == 0 &&
    comparison.candidate_unknown == 0 &&
    (!complete || complete_coverage) &&
    platforms.all(row => row.allowed),
  }
}
