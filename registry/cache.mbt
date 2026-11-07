///|
/// Reuse bytes from caller-owned cache storage. Bytes are verified against the
/// current private request, not trusted from a cache-hit flag or file name.
/// Root metadata without a mediaType needs an unambiguous recognized shape.
pub fn PullSession::accept_cached(
  self : PullSession,
  body : Bytes,
) -> Unit raise @model.MoonOciError {
  let request = match self.next() {
    Some(request) => request
    None => raise @model.InvalidArgument("pull has no pending cache response")
  }
  if body.length() > self.body_limit() {
    raise @model.ResourceLimitExceeded("cached response exceeds body quota")
  }
  let media = match request.media_type {
    Some(media) => media
    None => {
      if @digest.sha256(body) != request.digest {
        raise @model.DigestMismatch("cached root digest mismatch")
      }
      let fields = match @codec.parse_json_document(body) {
        Object(fields) => fields
        _ => raise @model.InvalidOci("cached root must be metadata")
      }
      match fields.get("mediaType") {
        Some(String(media)) => media
        None =>
          match
            (
              fields.get("manifests"),
              fields.get("config"),
              fields.get("layers"),
            ) {
            (Some(Array(_)), None, None) => @model.media_type_index
            (None, Some(Object(_)), Some(Array(_))) =>
              @model.media_type_manifest
            _ =>
              raise @model.InvalidOci(
                "cached root has ambiguous or unrecognized metadata shape",
              )
          }
        _ => raise @model.InvalidOci("cached root mediaType must be a string")
      }
    }
  }
  self.accept(
    200,
    [
      { key: "Content-Type", value: media, },
      { key: "Content-Length", value: body.length().to_string(), },
    ],
    body,
  )
  self.cached_bytes += body.length().to_int64()
  self.cached_requests += 1
}

///|
pub fn PullSession::cached_requests(self : PullSession) -> Int32 {
  self.cached_requests
}

///|
pub fn PullSession::cached_bytes(self : PullSession) -> Int64 {
  self.cached_bytes
}

///|
/// Accepted entity bytes only; excludes rejected attempts, headers and tokens.
pub fn PullSession::accepted_network_bytes(self : PullSession) -> Int64 {
  self.accepted_bytes - self.cached_bytes
}

///|
pub fn pull_statistics(session : PullSession) -> Json {
  let value : Json = {
    "schema": Json::string("moonoci.registry-pull-statistics.v1"),
    "accepted_requests": Json::number(session.accepted_requests().to_double()),
    "planned_requests": Json::number(session.planned_requests().to_double()),
    "cached_requests": Json::number(session.cached_requests().to_double()),
    "cached_bytes": Json::string(session.cached_bytes().to_string()),
    "accepted_entity_bytes": Json::string(session.accepted_bytes().to_string()),
    "accepted_network_bytes": Json::string(
      session.accepted_network_bytes().to_string(),
    ),
    "reserved_unique_bytes": Json::string(session.reserved_bytes().to_string()),
    "responses_complete": Json::boolean(session.next() is None),
    "complete": Json::boolean(session.is_verified()),
  }
  value
}

///|
pub fn pull_statistics_json(session : PullSession) -> String {
  pull_statistics(session).stringify()
}
