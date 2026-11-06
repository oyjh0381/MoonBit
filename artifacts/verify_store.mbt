///|
pub(all) struct StoreFinding {
  code : String
  digest : String?
  message : String
}

///|
pub(all) struct StoreVerification {
  valid : Bool
  complete : Bool
  images_checked : Int32
  artifacts_checked : Int32
  artifact_payload_bytes : Int64
  findings : Array[StoreFinding]
}

///|
/// Check advertised image branches plus recognized artifact payload closures.
/// Unknown media block this verification profile without declaring them corrupt.
/// Unreferenced physical blobs and subject authentication remain out of scope.
pub fn verify_store(
  source : @layout.MemoryLayout,
  artifact_limits~ : ArtifactLimits = ArtifactLimits::default(),
  graph_limits~ : @graph.WalkLimits = @graph.WalkLimits::default(),
  require_subject~ : Bool = false,
  max_total_payload_bytes~ : Int64 = 536870912L,
) -> StoreVerification raise @model.MoonOciError {
  validate_limits(artifact_limits)
  if max_total_payload_bytes < 1L {
    raise @model.InvalidArgument("store payload budget must be positive")
  }
  let findings : Array[StoreFinding] = []
  let walk = @graph.walk_indexes(source, limits=graph_limits) catch {
    error =>
      return {
        valid: false,
        complete: false,
        images_checked: 0,
        artifacts_checked: 0,
        artifact_payload_bytes: 0L,
        findings: [
          { code: error.code(), digest: None, message: error.message(), },
        ],
      }
  }
  let unknown = walk.skipped.filter(item => item.reason == "unknown-media-type")
  for item in unknown {
    findings.push({
      code: "unverified-media",
      digest: Some(item.descriptor.digest.to_string()),
      message: "descriptor media type is outside the verification profile",
    })
  }
  let mut images_checked = 0
  try {
    let flat = @graph.flatten_images(
      source,
      limits=graph_limits,
      allow_skipped=true,
    )
    let seen : Map[String, Bool] = Map([])
    for descriptor in @codec.decode_index(flat.index()).manifests {
      seen[descriptor.digest.to_string()] = true
    }
    images_checked = seen.length()
  } catch {
    error =>
      findings.push({
        code: error.code(),
        digest: None,
        message: error.message(),
      })
  }
  let seen : Map[String, Bool] = Map([])
  let mut artifacts_checked = 0
  let mut total = 0L
  let mut reserved = 0L
  for item in walk.skipped {
    if item.reason != "non-image-config" ||
      seen.contains(item.descriptor.digest.to_string()) {
      continue
    }
    seen[item.descriptor.digest.to_string()] = true
    try {
      let manifest = decode_manifest(source.require_blob(item.descriptor))
      let mut declared = 0L
      for payload in manifest.payloads {
        if payload.size < 0L ||
          payload.size > max_total_payload_bytes - reserved - declared {
          raise @model.ResourceLimitExceeded(
            "store artifact payload budget exceeded",
          )
        }
        declared += payload.size
      }
      // Reserve work before hashing: failures must not reset the aggregate
      // budget and permit unbounded retries across distinct corrupt artifacts.
      reserved += declared
      let observed = inspect(
        source,
        item.descriptor,
        limits=artifact_limits,
        require_subject~,
      )
      total += observed.payload_bytes
      artifacts_checked += 1
    } catch {
      error =>
        findings.push({
          code: error.code(),
          digest: Some(item.descriptor.digest.to_string()),
          message: error.message(),
        })
    }
  }
  {
    valid: findings.is_empty(),
    complete: unknown.is_empty(),
    images_checked,
    artifacts_checked,
    artifact_payload_bytes: total,
    findings,
  }
}

///|
pub fn verification_json(report : StoreVerification) -> String {
  let findings : Array[Json] = report.findings.map(f => {
    "code": Json::string(f.code),
    "message": Json::string(f.message),
    "digest": match f.digest {
      Some(d) => Json::string(d)
      None => Json::null()
    },
  })
  let result : Json = {
    "schema": "moonoci.store-verification.v1",
    "valid": Json::boolean(report.valid),
    "complete": Json::boolean(report.complete),
    "images_checked": Json::number(report.images_checked.to_double()),
    "artifacts_checked": Json::number(report.artifacts_checked.to_double()),
    "artifact_payload_bytes": Json::string(
      report.artifact_payload_bytes.to_string(),
    ),
    "findings": Json::array(findings),
  }
  result.stringify()
}
