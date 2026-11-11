///|
pub(all) enum PlatformTransition {
  Unavailable
  Introduced
  Removed
  Unchanged
  Updated
  AmbiguousMatch
}

///|
pub(all) struct PlatformPair {
  platform : @model.Platform
  baseline : PlatformMatch
  candidate : PlatformMatch
  transition : PlatformTransition
}

///|
pub(all) struct ReleaseComparison {
  baseline_index : @model.Digest
  candidate_index : @model.Digest
  platforms : Array[PlatformPair]
  baseline_unknown : Int32
  candidate_unknown : Int32
}

///|
fn classify(
  before : PlatformMatch,
  after : PlatformMatch,
) -> PlatformTransition {
  match (before, after) {
    (Ambiguous(_), _) | (_, Ambiguous(_)) => AmbiguousMatch
    (Missing, Missing) => Unavailable
    (Missing, Unique(_)) => Introduced
    (Unique(_), Missing) => Removed
    (Unique(a), Unique(b)) => if a == b { Unchanged } else { Updated }
  }
}

///|
/// Pair required platforms across two externally pinned index trees.
/// A matching manifest digest describes metadata identity. Filesystem
/// verification and rollout policy are separate from this comparison.
pub fn compare_releases(
  baseline : @layout.MemoryLayout,
  baseline_pin : @model.Digest,
  candidate : @layout.MemoryLayout,
  candidate_pin : @model.Digest,
  required : Array[@model.Platform],
  limits~ : @graph.WalkLimits = @graph.WalkLimits::default(),
) -> ReleaseComparison raise @model.MoonOciError {
  let before = coverage(baseline, baseline_pin, required, limits~)
  let after = coverage(candidate, candidate_pin, required, limits~)
  pair_coverage(before, after)
}

///|
fn pair_coverage(
  before : ReleaseCoverage,
  after : ReleaseCoverage,
) -> ReleaseComparison {
  let platforms = []
  for i, row in before.required {
    let left = row.match_result
    let right = after.required[i].match_result
    platforms.push({
      platform: row.platform,
      baseline: left,
      candidate: right,
      transition: classify(left, right),
    })
  }
  {
    baseline_index: before.index_pin,
    candidate_index: after.index_pin,
    platforms,
    baseline_unknown: before.unknown_descriptors,
    candidate_unknown: after.unknown_descriptors,
  }
}
