///|
pub(all) enum PlatformMatch {
  Missing
  Unique(@model.Digest)
  Ambiguous(Array[@model.Digest])
}

///|
pub(all) struct PlatformCoverage {
  platform : @model.Platform
  match_result : PlatformMatch
}

///|
pub(all) struct ReleaseCoverage {
  index_pin : @model.Digest
  required : Array[PlatformCoverage]
  unknown_descriptors : Int32
  non_images : Int32
}

///|
fn platform_key(platform : @model.Platform) -> String {
  fn optional(value : String?) -> Json {
    match value {
      None => Json::null()
      Some(value) => Json::string(value)
    }
  }
  Json::array([
    Json::string(platform.os),
    Json::string(platform.architecture),
    optional(platform.variant),
    optional(platform.os_version),
  ]).stringify()
}

///|
/// Compare required platforms with the pinned layout's verified index and
/// image configuration metadata. A repeated manifest digest is one match.
/// This report describes platform coverage before filesystem validation.
pub fn coverage(
  source : @layout.MemoryLayout,
  expected_index : @model.Digest,
  required : Array[@model.Platform],
  limits~ : @graph.WalkLimits = @graph.WalkLimits::default(),
) -> ReleaseCoverage raise @model.MoonOciError {
  if required.is_empty() || required.length() > 256 {
    raise @model.InvalidArgument("rollout requires between 1 and 256 platforms")
  }
  let targets : Map[String, Map[String, @model.Digest]] = Map([])
  let keys = required.map(platform => {
    if platform.os.is_empty() || platform.architecture.is_empty() {
      raise @model.InvalidArgument("rollout platform needs OS and architecture")
    }
    let key = platform_key(platform)
    if targets.contains(key) {
      raise @model.InvalidArgument("duplicate required rollout platform")
    }
    targets[key] = Map([])
    key
  })
  let walk = @graph.walk_pinned(source, expected_index, limits~)
  for image in walk.images {
    if targets.get(platform_key(image.platform)) is Some(matches) {
      let digest = image.descriptor.digest
      matches[digest.to_string()] = digest
    }
  }
  let rows = []
  for i, platform in required {
    let matches = targets[keys[i]].values().collect()
    let match_result = match matches {
      [] => Missing
      [digest] => Unique(digest)
      _ => {
        matches.sort_by((a, b) => a.to_string().compare(b.to_string()))
        Ambiguous(matches)
      }
    }
    rows.push({ platform, match_result, })
  }
  let mut unknown_descriptors = 0
  let mut non_images = 0
  for skipped in walk.skipped {
    if skipped.reason == "non-image-config" {
      non_images += 1
    } else {
      unknown_descriptors += 1
    }
  }
  {
    index_pin: expected_index,
    required: rows,
    unknown_descriptors,
    non_images,
  }
}
