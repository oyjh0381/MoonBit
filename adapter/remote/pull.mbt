///|
fn cached_candidate(
  cache : @layout.MemoryLayout?,
  index : (Bytes, @model.Digest)?,
  pin : @model.Digest,
) -> Bytes? {
  match cache {
    None => None
    Some(cache) =>
      match cache.get_blob(pin) {
        Some(bytes) => Some(bytes)
        None =>
          match index {
            Some((bytes, digest)) if digest == pin => Some(bytes)
            _ => None
          }
      }
  }
}

///|
async fn drain_registry_pull(
  transport : RegistryTransport,
  repository : String,
  session : @registry.PullSession,
  cache : @layout.MemoryLayout?,
  fallback_cache~ : @layout.MemoryLayout? = None,
) -> @layout.MemoryLayout {
  let cached_index = cache.map(cache => {
    (cache.index(), @digest.sha256(cache.index()))
  })
  let fallback_index = fallback_cache.map(cache => {
    (cache.index(), @digest.sha256(cache.index()))
  })
  while session.next() is Some(request) {
    let candidate = match
      cached_candidate(cache, cached_index, request.digest) {
      Some(bytes) => Some(bytes)
      None => cached_candidate(fallback_cache, fallback_index, request.digest)
    }
    if candidate is Some(bytes) {
      session.accept_cached(bytes)
      continue
    }
    let remaining = transport.options.pull_limits.max_total_bytes -
      transport.accepted_network_bytes
    let zero_size = request.size == Some(0L)
    if remaining < 1L && !zero_size {
      raise @model.ResourceLimitExceeded(
        "registry aggregate accepted network entity quota exhausted",
      )
    }
    let limit = if zero_size {
      1
    } else if remaining < session.body_limit().to_int64() {
      remaining.to_int()
    } else {
      session.body_limit()
    }
    let response = transport.get(repository, request, limit)
    session.accept(response.status, response.headers, response.body)
    transport.accepted_network_bytes += response.body.length().to_int64()
  }
  session.finish()
}

///|
async fn pull_impl(
  transport : RegistryTransport,
  repository : String,
  session : @registry.PullSession,
  cache : @layout.MemoryLayout?,
  expected : @model.Digest,
) -> RegistryPullResult {
  let layout = drain_registry_pull(transport, repository, session, cache)
  let statistics : Json = {
    "core": @registry.pull_statistics(session),
    "http_requests": Json::number(transport.requests.to_double()),
    "auth_requests": Json::number(transport.auth_requests.to_double()),
    "retries": Json::number(transport.retries.to_double()),
    "source_root": Json::string(expected.to_string()),
    "output_index": Json::string(@digest.sha256(layout.index()).to_string()),
  }
  { layout, source_root: expected, statistics: statistics.stringify(), }
}

///|
/// Native read-only Registry HTTP pull. Credentials stay in memory and are sent
/// only to the original registry origin. Returned layout is independently mutable;
/// no destination is published by this network function.
pub async fn pull_registry(
  origin : String,
  repository : String,
  reference : String,
  expected : @model.Digest,
  options~ : RegistryOptions = RegistryOptions::default(),
  cache? : @layout.MemoryLayout,
  bearer_token? : String,
) -> RegistryPullResult {
  let transport = RegistryTransport::new(origin, options, bearer_token)
  let session = @registry.PullSession::new(
    repository,
    reference,
    expected,
    limits=options.pull_limits,
  )
  @async.with_timeout(options.total_timeout_ms, () => {
    pull_impl(transport, repository, session, cache, expected)
  }) catch {
    @async.TimeoutError =>
      raise @model.IoFailure(
        "registry pull exceeded its cooperative time budget",
      )
    error => raise error
  }
}
