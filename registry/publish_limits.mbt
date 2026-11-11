///|
/// Resource bounds for an execution where none of the destination objects
/// already exist. Bounds are checked before the first network request.
pub(all) struct PublishLimits {
  max_object_bytes : Int64
  max_total_bytes : Int64
  max_requests : Int32
}

///|
pub fn PublishLimits::default() -> PublishLimits {
  {
    max_object_bytes: 268435456L,
    max_total_bytes: 536870912L,
    max_requests: 16384,
  }
}

///|
pub(all) struct PublishEstimate {
  body_bytes : Int64
  largest_object : Int64
  max_requests : Int32
}

///|
/// Budget one HEAD per object, two more requests per missing blob, and
/// one PUT per missing child manifest. The tag gets two HEAD checks,
/// at most one PUT, and one GET of the exact root manifest.
pub fn PublishPlan::preflight(
  self : PublishPlan,
  limits~ : PublishLimits = PublishLimits::default(),
) -> PublishEstimate raise @model.MoonOciError {
  if limits.max_object_bytes < 1L ||
    limits.max_object_bytes > 536870912L ||
    limits.max_total_bytes < 1L ||
    limits.max_total_bytes > 8589934592L ||
    limits.max_requests < 1 ||
    limits.max_requests > 100000 {
    raise @model.InvalidArgument("invalid Registry publication limits")
  }
  let max_requests = self.blobs.length() * 3 +
    (self.manifests.length() - 1) * 2 +
    4
  if max_requests > limits.max_requests {
    raise @model.ResourceLimitExceeded(
      "publication exceeds worst-case request budget",
    )
  }
  let mut body_bytes = 0L
  let mut largest_object = 0L
  for objects in [self.blobs, self.manifests] {
    for object in objects {
      let size = object.data.length().to_int64()
      if size > limits.max_object_bytes ||
        size > limits.max_total_bytes - body_bytes {
        raise @model.ResourceLimitExceeded(
          "publication exceeds request body budget",
        )
      }
      largest_object = largest_object.max(size)
      body_bytes += size
    }
  }
  { body_bytes, largest_object, max_requests, }
}
