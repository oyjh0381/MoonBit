///|
// A private cache containing only content that has passed a pull session. The
// caller's optional cache is never mutated and unused cached orphans stay out.
fn cache_verified_closure(
  pool : @layout.MemoryLayout,
  part : @layout.MemoryLayout,
  limits : @registry.PullLimits,
  initial_bytes : Int64,
) -> Int64 raise @model.MoonOciError {
  let mut bytes = initial_bytes
  for record in part.blob_records() {
    let descriptor = record.descriptor()
    if pool.get_blob(descriptor.digest) is None {
      if pool.blob_count() == limits.max_objects ||
        record.data().length().to_int64() > limits.max_total_bytes - bytes {
        raise @model.ResourceLimitExceeded(
          "verified registry cache exceeds bundle quota",
        )
      }
      ignore(pool.put_blob(descriptor.media_type, record.data()))
      bytes += record.data().length().to_int64()
    }
  }
  bytes
}

///|
async fn bundle_impl(
  transport : RegistryTransport,
  repository : String,
  reference : String,
  expected : @model.Digest,
  subject : @model.Digest,
  artifact_type : String?,
  discovery_limits : @registry.DiscoveryLimits,
  cache : @layout.MemoryLayout?,
) -> RegistryBundleResult {
  let limits = transport.options.pull_limits
  let session = @registry.PullSession::new(
    repository,
    reference,
    expected,
    limits~,
  )
  let base = drain_registry_pull(transport, repository, session, cache)
  ignore(
    @artifacts.resolve_subject(base, subject, limits={
      max_depth: limits.max_depth,
      max_visits: limits.max_visits,
      max_metadata_bytes: limits.max_total_bytes,
    }),
  )
  let discovery = discover_impl(
    transport, repository, subject, artifact_type, discovery_limits,
  )
  let pool = @layout.MemoryLayout::new()
  pool.set_index(base.index())
  let mut cached_bytes = cache_verified_closure(pool, base, limits, 0L)
  let fetched : Array[@layout.MemoryLayout] = []
  for advertisement in discovery.advertisements {
    let root = advertisement.descriptor
    let session = @registry.PullSession::new(
      repository,
      root.digest.to_string(),
      root.digest,
      limits~,
    )
    let part = drain_registry_pull(
      transport,
      repository,
      session,
      Some(pool),
      fallback_cache=cache,
    )
    cached_bytes = cache_verified_closure(pool, part, limits, cached_bytes)
    fetched.push(part)
  }
  let bundle = @registry.assemble_referrer_bundle(
    base,
    @digest.sha256(base.index()),
    subject,
    discovery.advertisements,
    fetched,
    limits~,
  )
  let report : Json = {
    "schema": Json::string("moonoci.registry-bundle.v1"),
    "trusted_source_root": Json::string(expected.to_string()),
    "http_requests": Json::number(transport.requests.to_double()),
    "auth_requests": Json::number(transport.auth_requests.to_double()),
    "retries": Json::number(transport.retries.to_double()),
    "accepted_network_bytes": Json::string(
      transport.accepted_network_bytes.to_string(),
    ),
    "discovery": @codec.parse_json_document(@utf8.encode(discovery.statistics)),
    "bundle": @codec.parse_json_document(@utf8.encode(bundle.receipt)),
  }
  { layout: bundle.layout, statistics: report.stringify(), }
}

///|
/// Pull a pinned release plus verified immediate referrers of one local metadata
/// subject. One transport shares auth/request/accepted-entity budgets, retry policy and
/// one total timeout. Does not recursively discover referrers-of-referrers.
pub async fn pull_with_referrers(
  origin : String,
  repository : String,
  reference : String,
  expected : @model.Digest,
  subject : @model.Digest,
  artifact_type? : String,
  options~ : RegistryOptions = RegistryOptions::default(),
  discovery_limits~ : @registry.DiscoveryLimits = @registry.DiscoveryLimits::default(),
  cache? : @layout.MemoryLayout,
  bearer_token? : String,
) -> RegistryBundleResult {
  let transport = RegistryTransport::new(origin, options, bearer_token)
  discovery_limits.validate()
  @async.with_timeout(options.total_timeout_ms, () => {
    bundle_impl(
      transport, repository, reference, expected, subject, artifact_type, discovery_limits,
      cache,
    )
  }) catch {
    @async.TimeoutError =>
      raise @model.IoFailure(
        "registry bundle exceeded its cooperative time budget",
      )
    error => raise error
  }
}
