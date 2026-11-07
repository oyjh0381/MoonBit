///|
async fn pull_impl(
  origin : @registry.RegistryOrigin,
  repository : String,
  session : @registry.PullSession,
  options : RegistryOptions,
  cache : @layout.MemoryLayout?,
  authorization : String?,
  expected : @model.Digest,
) -> RegistryPullResult {
  let transport : RegistryTransport = {
    origin,
    options,
    authorization,
    requests: 0,
    auth_requests: 0,
    retries: 0,
  }
  let cached_index = cache.map(cache => {
    (cache.index(), @digest.sha256(cache.index()))
  })
  while session.next() is Some(request) {
    let candidate = match cache {
      None => None
      Some(cache) =>
        match cache.get_blob(request.digest) {
          Some(bytes) => Some(bytes)
          None =>
            match cached_index {
              Some((bytes, pin)) if pin == request.digest => Some(bytes)
              _ => None
            }
        }
    }
    if candidate is Some(bytes) {
      session.accept_cached(bytes)
      continue
    }
    let response = transport.get(repository, request, session.body_limit())
    session.accept(response.status, response.headers, response.body)
  }
  let layout = session.finish()
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
  options.validate()
  let options = {
    ..options,
    allowed_realms: options.allowed_realms.copy(),
    allowed_blob_origins: options.allowed_blob_origins.copy(),
  }
  let origin = @registry.RegistryOrigin::parse(
    origin,
    allow_http=options.allow_http,
  )
  let session = @registry.PullSession::new(
    repository,
    reference,
    expected,
    limits=options.pull_limits,
  )
  let authorization = bearer_token.map(token => {
    @registry.bearer_authorization(token)
  })
  @async.with_timeout(options.total_timeout_ms, () => {
    pull_impl(
      origin, repository, session, options, cache, authorization, expected,
    )
  }) catch {
    @async.TimeoutError =>
      raise @model.IoFailure(
        "registry pull exceeded its cooperative time budget",
      )
    error => raise error
  }
}
