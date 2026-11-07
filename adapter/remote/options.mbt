///|
pub(all) struct RegistryOptions {
  allow_http : Bool
  ca_file : String?
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
}
