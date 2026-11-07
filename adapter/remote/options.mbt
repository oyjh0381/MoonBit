///|
pub(all) struct RegistryOptions {
  allow_http : Bool
  ca_file : String?
  proxy_origin : String?
  request_timeout_ms : Int32
  total_timeout_ms : Int32
  max_http_requests : Int32
  max_redirects : Int32
  max_auth_requests : Int32
  max_retries : Int32
  max_retry_delay_ms : Int32
  allowed_realms : Array[@registry.RegistryOrigin]
  allowed_blob_origins : Array[@registry.RegistryOrigin]
  pull_limits : @registry.PullLimits
}

///|
pub fn RegistryOptions::default() -> RegistryOptions {
  {
    allow_http: false,
    ca_file: None,
    proxy_origin: None,
    request_timeout_ms: 30000,
    total_timeout_ms: 300000,
    max_http_requests: 16384,
    max_redirects: 3,
    max_auth_requests: 2,
    max_retries: 2,
    max_retry_delay_ms: 5000,
    allowed_realms: [],
    allowed_blob_origins: [],
    pull_limits: @registry.PullLimits::default(),
  }
}

///|
pub fn RegistryOptions::validate(
  self : RegistryOptions,
) -> Unit raise @model.MoonOciError {
  self.pull_limits.validate()
  if self.proxy_origin is Some(origin) {
    ignore(@registry.RegistryOrigin::parse(origin, allow_http=true))
  }
  if self.ca_file is Some(path) {
    if path.is_empty() || path.length() > 4096 || path.contains_char('\u{0000}') {
      raise @model.InvalidArgument("invalid registry CA file path")
    }
  }
  if self.request_timeout_ms < 1 ||
    self.request_timeout_ms > 120000 ||
    self.total_timeout_ms < 1 ||
    self.total_timeout_ms > 3600000 ||
    self.max_http_requests < 1 ||
    self.max_http_requests > 100000 ||
    self.max_redirects < 0 ||
    self.max_redirects > 8 ||
    self.max_auth_requests < 0 ||
    self.max_auth_requests > 8 ||
    self.max_retries < 0 ||
    self.max_retries > 8 ||
    self.max_retry_delay_ms < 0 ||
    self.max_retry_delay_ms > 60000 ||
    self.allowed_realms.length() > 16 ||
    self.allowed_blob_origins.length() > 16 {
    raise @model.InvalidArgument("invalid native registry transport options")
  }
}

///|
pub(all) struct RegistryPullResult {
  layout : @layout.MemoryLayout
  source_root : @model.Digest
  statistics : String
}

///|
pub(all) struct RegistryDiscoveryResult {
  advertisements : Array[@artifacts.ReferrerAdvertisement]
  statistics : String
}

///|
pub(all) struct RegistryBundleResult {
  layout : @layout.MemoryLayout
  statistics : String
}

///|
fn RegistryTransport::new(
  origin : String,
  options : RegistryOptions,
  bearer_token : String?,
) -> RegistryTransport raise @model.MoonOciError {
  options.validate()
  let options = {
    ..options,
    proxy_origin: options.proxy_origin.map(value => {
      @registry.RegistryOrigin::parse(value, allow_http=true).url()
    }),
    allowed_realms: options.allowed_realms.copy(),
    allowed_blob_origins: options.allowed_blob_origins.copy(),
  }
  {
    origin: @registry.RegistryOrigin::parse(
      origin,
      allow_http=options.allow_http,
    ),
    options,
    authorization: bearer_token.map(token => {
      @registry.bearer_authorization(token)
    }),
    requests: 0,
    auth_requests: 0,
    retries: 0,
    accepted_network_bytes: 0L,
  }
}

///|
priv struct HttpEntity {
  status : Int32
  headers : Array[@model.KeyValue]
  body : Bytes
}

///|
priv struct RegistryTransport {
  origin : @registry.RegistryOrigin
  options : RegistryOptions
  mut authorization : String?
  mut requests : Int32
  mut auth_requests : Int32
  mut retries : Int32
  mut accepted_network_bytes : Int64
}
