///|
async fn discover_impl(
  transport : RegistryTransport,
  repository : String,
  subject : @model.Digest,
  artifact_type : String?,
  limits : @registry.DiscoveryLimits,
) -> RegistryDiscoveryResult {
  let session = @registry.ReferrerSession::new(
    transport.origin,
    repository,
    subject,
    artifact_type?,
    limits~,
  )
  while session.next_path() is Some(path) {
    let request : @registry.FetchRequest = {
      path,
      kind: "referrers",
      digest: subject,
      size: None,
      media_type: None,
      depth: 0,
    }
    let response = transport.get(repository, request, session.body_limit())
    session.accept(response.status, response.headers, response.body)
  }
  let report = session.report()
  let statistics = match report {
    Object(fields) => {
      fields["http_requests"] = Json::number(transport.requests.to_double())
      fields["auth_requests"] = Json::number(
        transport.auth_requests.to_double(),
      )
      fields["retries"] = Json::number(transport.retries.to_double())
      report.stringify()
    }
    _ => abort("referrer report is an object")
  }
  { advertisements: session.advertisements(), statistics, }
}

///|
/// Read-only discovery, with the same authentication/redirect/time policy as
/// pinned pulls. Returned descriptors are advertisements, not verified claims.
pub async fn discover_referrers(
  origin : String,
  repository : String,
  subject : @model.Digest,
  artifact_type? : String,
  options~ : RegistryOptions = RegistryOptions::default(),
  limits~ : @registry.DiscoveryLimits = @registry.DiscoveryLimits::default(),
  bearer_token? : String,
) -> RegistryDiscoveryResult {
  let transport = RegistryTransport::new(origin, options, bearer_token)
  limits.validate()
  @async.with_timeout(options.total_timeout_ms, () => {
    discover_impl(transport, repository, subject, artifact_type, limits)
  }) catch {
    @async.TimeoutError =>
      raise @model.IoFailure(
        "registry discovery exceeded its cooperative time budget",
      )
    error => raise error
  }
}
