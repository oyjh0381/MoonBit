///|
async fn[T] with_registry_client(
  url : @registry.RegistryUrl,
  headers : Map[String, String],
  ca_file : String?,
  proxy_origin : String?,
  action : async (@http.Client) -> T,
) -> T {
  let trust : @tls.TrustedRoot = match ca_file {
    None => SystemRoot
    Some(path) => CustomPemFile(path)
  }
  let proxy = match proxy_origin {
    None => None
    Some(origin) =>
      Some(@http.Client(origin, trust~)) catch {
        _ =>
          raise @model.IoFailure(
            "registry proxy connection or TLS setup failed",
          )
      }
  }
  defer (if proxy is Some(proxy) { proxy.close() })
  let headers : @http.Headers = Map(
    headers
    .iter()
    .map(pair => (@http.CaseInsensitiveString(pair.0), pair.1))
    .collect(),
  )
  let client = @http.Client(url.origin().url(), headers~, trust~, proxy?) catch {
    _ => raise @model.IoFailure("registry connection or TLS setup failed")
  }
  defer client.close()
  action(client)
}

///|
fn registry_response_headers(
  response : @http.Response,
) -> Array[@model.KeyValue] {
  response.headers
  .iter()
  .map(pair => ({ key: pair.0.to_string(), value: pair.1, } : @model.KeyValue))
  .collect()
}

///|
async fn fetch_entity(
  url : @registry.RegistryUrl,
  headers : Map[String, String],
  max_bytes : Int32,
  expected_size : Int64?,
  ca_file : String?,
  proxy_origin : String?,
) -> HttpEntity {
  with_registry_client(url, headers, ca_file, proxy_origin, client => {
    fetch_connected(client, url.path(), max_bytes, expected_size)
  })
}

///|
async fn fetch_connected(
  client : @http.Client,
  path : String,
  max_bytes : Int32,
  expected_size : Int64?,
) -> HttpEntity {
  let response = client.get(path) catch {
    _ => raise @model.IoFailure("registry request or response framing failed")
  }
  let headers = registry_response_headers(response)
  if response.code != 200 {
    // Error, redirect and auth bodies are not read into memory or echoed.
    return { status: response.code, headers, body: b"", }
  }
  @registry.check_response_head(
    response.code,
    headers,
    max_bytes,
    expected_size?,
  )
  let size = match expected_size {
    Some(size) => size
    None => @registry.content_length(headers).unwrap_or(max_bytes.to_int64())
  }
  let buffer = FixedArray::make(size.to_int() + 1, b'\x00')
  let mut received = 0
  while received < buffer.length() {
    let count = client.read(
      buffer,
      offset=received,
      max_len=buffer.length() - received,
    ) catch {
      _ =>
        raise @model.IoFailure(
          "registry body read was interrupted or malformed",
        )
    }
    if count == 0 {
      break
    }
    received += count
  }
  if received.to_int64() > size {
    raise @model.ResourceLimitExceeded(
      "registry body exceeds expected/maximum size",
    )
  }
  {
    status: response.code,
    headers,
    body: Bytes::from_array(buffer)[0:received].to_owned(),
  }
}

///|
async fn RegistryTransport::fetch_once(
  self : RegistryTransport,
  url : @registry.RegistryUrl,
  headers : Map[String, String],
  max_bytes : Int32,
  expected_size : Int64?,
) -> HttpEntity {
  if self.requests == self.options.max_http_requests {
    raise @model.ResourceLimitExceeded(
      "registry total HTTP request quota exceeded",
    )
  }
  self.requests += 1
  @async.with_timeout(self.options.request_timeout_ms, () => {
    fetch_entity(
      url,
      Map(headers.iter().collect()),
      max_bytes,
      expected_size,
      self.options.ca_file,
      self.options.proxy_origin,
    )
  }) catch {
    @async.TimeoutError =>
      raise @model.IoFailure("registry HTTP request timed out")
    error => raise error
  }
}

///|
async fn RegistryTransport::fetch(
  self : RegistryTransport,
  url : @registry.RegistryUrl,
  headers : Map[String, String],
  max_bytes : Int32,
  expected_size : Int64?,
) -> HttpEntity {
  let mut attempt = 0
  while true {
    let result = Some(self.fetch_once(url, headers, max_bytes, expected_size)) catch {
      @model.IoFailure(_) if attempt < self.options.max_retries => None
      error => raise error
    }
    let (status, response_headers) = match result {
      Some(response) => (response.status, response.headers)
      None => (0, [])
    }
    let delay = @registry.retry_delay(
      status,
      response_headers,
      attempt,
      max_retries=self.options.max_retries,
      max_delay_ms=self.options.max_retry_delay_ms,
    )
    match delay {
      None =>
        match result {
          Some(response) => return response
          None => raise @model.IoFailure("registry read retries exhausted")
        }
      Some(delay) => {
        if self.requests == self.options.max_http_requests {
          raise @model.ResourceLimitExceeded(
            "registry HTTP quota exhausted before retry",
          )
        }
        attempt += 1
        self.retries += 1
        if delay > 0 {
          @async.sleep(delay)
        }
      }
    }
  }
  abort("unreachable registry retry state")
}

///|
async fn RegistryTransport::authenticate(
  self : RegistryTransport,
  headers : Array[@model.KeyValue],
  repository : String,
) -> Unit {
  if self.auth_requests == self.options.max_auth_requests {
    raise @model.ResourceLimitExceeded(
      "registry authentication request quota exceeded",
    )
  }
  let challenge = match @registry.single_header(headers, "www-authenticate") {
    Some(value) => @registry.parse_bearer_challenge(value)
    None =>
      raise @model.IoFailure(
        "registry unauthorized response has no Bearer challenge",
      )
  }
  let url = challenge.token_request(
    self.origin,
    repository,
    allowed_realms=self.options.allowed_realms,
    allow_http=self.options.allow_http,
  )
  self.auth_requests += 1
  // Authorization to the registry is deliberately not forwarded to the realm.
  let response = self.fetch(
    url,
    Map([("Accept", "application/json"), ("Accept-Encoding", "identity")]),
    65536,
    None,
  )
  if response.status != 200 {
    raise @model.IoFailure("registry token endpoint refused the request")
  }
  self.authorization = Some(@registry.decode_bearer_token(response.body))
}

///|
async fn RegistryTransport::get(
  self : RegistryTransport,
  repository : String,
  request : @registry.FetchRequest,
  max_bytes : Int32,
) -> HttpEntity {
  let mut url = self.origin.request_url(request.path)
  let mut redirects = 0
  while true {
    let headers = Map([("Accept-Encoding", "identity"), ("Connection", "close")])
    if request.kind == "referrers" {
      headers["Accept"] = "application/vnd.oci.image.index.v1+json"
    } else if request.kind == "manifest" {
      for header in @registry.manifest_headers() {
        headers[header.key] = header.value
      }
    } else {
      headers["Accept"] = "application/octet-stream"
    }
    if url.origin().same_origin(self.origin) {
      if self.authorization is Some(value) {
        headers["Authorization"] = value
      }
    }
    let response = self.fetch(url, headers, max_bytes, request.size)
    if response.status == 401 && url.origin().same_origin(self.origin) {
      self.authenticate(response.headers, repository)
      continue
    }
    if [301, 302, 303, 307, 308].contains(response.status) {
      if redirects == self.options.max_redirects {
        raise @model.ResourceLimitExceeded("registry redirect quota exceeded")
      }
      let location = match
        @registry.single_header(response.headers, "location") {
        Some(location) => location
        None => raise @model.InvalidOci("registry redirect has no Location")
      }
      let next = url
        .origin()
        .resolve(location, allow_http=self.options.allow_http)
      if !url.origin().is_http() && next.origin().is_http() {
        raise @model.InvalidArgument("registry redirect cannot downgrade HTTPS")
      }
      if !next.origin().same_origin(self.origin) {
        if request.kind != "blob" ||
          !self.options.allowed_blob_origins.any(origin => {
            origin.same_origin(next.origin())
          }) {
          raise @model.InvalidArgument(
            "cross-origin registry redirect is not explicitly allowed for this Blob",
          )
        }
      }
      redirects += 1
      url = next
      continue
    }
    return response
  }
  abort("unreachable registry transport state")
}
