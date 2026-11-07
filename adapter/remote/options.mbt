///|
pub(all) struct RegistryOptions {
  allow_http : Bool
  request_timeout_ms : Int32
  total_timeout_ms : Int32
  max_http_requests : Int32
  max_redirects : Int32
  max_auth_requests : Int32
  allowed_realms : Array[@registry.RegistryOrigin]
  allowed_blob_origins : Array[@registry.RegistryOrigin]
  pull_limits : @registry.PullLimits
}

///|
pub fn RegistryOptions::default() -> RegistryOptions {
  {
    allow_http: false,
    request_timeout_ms: 30000,
    total_timeout_ms: 300000,
    max_http_requests: 16384,
    max_redirects: 3,
    max_auth_requests: 2,
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
}
