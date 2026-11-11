///|
pub(all) struct PublishOptions {
  allow_http : Bool
  ca_file : String?
  proxy_origin : String?
  request_timeout_ms : Int32
  total_timeout_ms : Int32
  limits : @registry.PublishLimits
}

///|
pub fn PublishOptions::default() -> PublishOptions {
  {
    allow_http: false,
    ca_file: None,
    proxy_origin: None,
    request_timeout_ms: 30000,
    total_timeout_ms: 300000,
    limits: @registry.PublishLimits::default(),
  }
}

///|
pub(all) struct PublicationReceipt {
  root : @model.Digest
  review_pin : @model.Digest
  requests : Int32
  uploaded_blobs : Int32
  reused_blobs : Int32
  uploaded_manifests : Int32
  reused_manifests : Int32
  uploaded_bytes : Int64
  tag_written : Bool
}

///|
priv struct PublishTransport {
  plan : @registry.PublishPlan
  options : PublishOptions
  authorization : String?
  mut requests : Int32
  mut uploaded_bytes : Int64
}

///|
fn PublishTransport::headers(
  self : PublishTransport,
  manifest : Bool,
) -> Map[String, String] {
  let headers = Map([("Accept-Encoding", "identity"), ("Connection", "close")])
  if manifest {
    for header in @registry.manifest_headers() {
      headers[header.key] = header.value
    }
  }
  if self.authorization is Some(value) {
    headers["Authorization"] = value
  }
  headers
}

///|
async fn PublishTransport::perform(
  self : PublishTransport,
  action : async () -> HttpEntity,
) -> HttpEntity {
  if self.requests >= self.options.limits.max_requests {
    raise @model.ResourceLimitExceeded(
      "registry publication request budget exhausted",
    )
  }
  self.requests += 1
  @async.with_timeout(self.options.request_timeout_ms, action) catch {
    @async.TimeoutError =>
      raise @model.IoFailure("registry publication request timed out")
    error => raise error
  }
}

///|
async fn PublishTransport::request_head(
  self : PublishTransport,
  url : @registry.RegistryUrl,
  verb : @http.RequestMethod,
  manifest : Bool,
  body? : @registry.PublishObject,
) -> HttpEntity {
  if !url.origin().same_origin(self.plan.origin()) {
    raise @model.InvalidArgument("registry publication request changed origin")
  }
  let headers = self.headers(manifest)
  let extra : @http.Headers = Map([])
  if verb is @http.Post {
    extra["Content-Length"] = "0"
  }
  if body is Some(object) {
    extra["Content-Length"] = object.data.length().to_string()
    extra["Content-Type"] = if manifest {
      object.media_type
    } else {
      "application/octet-stream"
    }
  }
  self.perform(() => {
    with_registry_client(
      url,
      headers,
      self.options.ca_file,
      self.options.proxy_origin,
      client => {
        let response = try {
          client.request(verb, url.path(), extra_headers=extra)
          if body is Some(object) {
            client.write(object.data)
          }
          client.end_request()
        } catch {
          _ =>
            raise @model.IoFailure(
              "registry publication request or response framing failed",
            )
        }
        {
          status: response.code,
          headers: registry_response_headers(response),
          body: b"",
        }
      },
    )
  })
}

///|
async fn PublishTransport::exists(
  self : PublishTransport,
  url : @registry.RegistryUrl,
  object : @registry.PublishObject,
  manifest : Bool,
) -> Bool {
  let response = self.request_head(url, @http.Head, manifest)
  @registry.publication_exists(response.status, response.headers, object)
}

///|
async fn PublishTransport::put(
  self : PublishTransport,
  url : @registry.RegistryUrl,
  object : @registry.PublishObject,
  manifest : Bool,
) -> Unit {
  let response = self.request_head(url, @http.Put, manifest, body=object)
  @registry.check_publication_written(
    response.status,
    response.headers,
    object.digest,
  )
  self.uploaded_bytes += object.data.length().to_int64()
}

///|
async fn PublishTransport::upload_blob(
  self : PublishTransport,
  object : @registry.PublishObject,
) -> Bool {
  let origin = self.plan.origin()
  let repository = self.plan.repository()
  let present = origin.request_url(
    @registry.blob_path(repository, object.digest),
  )
  if self.exists(present, object, false) {
    return false
  }
  let start = origin.request_url(@registry.blob_upload_path(repository))
  let response = self.request_head(start, @http.Post, false)
  let finish = @registry.finalize_blob_upload(
    origin,
    repository,
    response.status,
    response.headers,
    object.digest,
  )
  self.put(finish, object, false)
  true
}

///|
async fn PublishTransport::publish(
  self : PublishTransport,
  review_pin : @model.Digest,
) -> PublicationReceipt {
  let origin = self.plan.origin()
  let repository = self.plan.repository()
  let manifests = self.plan.manifests()
  let blobs = self.plan.blobs()
  let root = manifests[manifests.length() - 1]
  let tag_url = origin.request_url(
    @registry.manifest_path(repository, self.plan.tag()),
  )
  // Reject an existing different tag before creating any upload sessions.
  ignore(self.exists(tag_url, root, true))
  let mut uploaded_blobs = 0
  for object in blobs {
    if self.upload_blob(object) {
      uploaded_blobs += 1
    }
  }
  let mut uploaded_manifests = 0
  for i in 0..<(manifests.length() - 1) {
    let object = manifests[i]
    let url = origin.request_url(
      @registry.manifest_path(repository, object.digest.to_string()),
    )
    if !self.exists(url, object, true) {
      self.put(url, object, true)
      uploaded_manifests += 1
    }
  }
  let tag_written = !self.exists(tag_url, root, true)
  if tag_written {
    self.put(tag_url, root, true)
  }
  let bytes = root.data.length()
  let response = self.perform(() => {
    fetch_entity(
      tag_url,
      self.headers(true),
      bytes,
      Some(bytes.to_int64()),
      self.options.ca_file,
      self.options.proxy_origin,
    )
  })
  ignore(
    @registry.verify_manifest_response(
      response.status,
      response.headers,
      response.body,
      root.digest,
      max_bytes=bytes,
      expected_size=bytes.to_int64(),
      expected_media=root.media_type,
    ),
  )
  {
    root: root.digest,
    review_pin,
    requests: self.requests,
    uploaded_blobs,
    reused_blobs: blobs.length() - uploaded_blobs,
    uploaded_manifests,
    reused_manifests: manifests.length() - 1 - uploaded_manifests,
    uploaded_bytes: self.uploaded_bytes,
    tag_written,
  }
}

///|
/// Publish a reviewed closure using bounded OCI Distribution requests. Tag
/// checks are create-or-identical and require a single writer per tag.
pub async fn publish_registry(
  plan : @registry.PublishPlan,
  expected_review : @model.Digest,
  options~ : PublishOptions = PublishOptions::default(),
  bearer_token? : String,
) -> PublicationReceipt {
  if plan.pin() != expected_review {
    raise @model.DigestMismatch("registry publication review pin mismatch")
  }
  ignore(plan.preflight(limits=options.limits))
  if plan.origin().is_http() && (!options.allow_http || bearer_token is Some(_)) {
    raise @model.InvalidArgument(
      "plaintext publication requires opt-in and no bearer token",
    )
  }
  // Reuse the existing CA, proxy and timeout validation without enabling
  // redirects, challenge handling or automatic retries for write requests.
  (
    {
      ..RegistryOptions::default(),
      ca_file: options.ca_file,
      proxy_origin: options.proxy_origin,
      request_timeout_ms: options.request_timeout_ms,
      total_timeout_ms: options.total_timeout_ms,
    } : RegistryOptions).validate()
  let options = {
    ..options,
    proxy_origin: options.proxy_origin.map(value => {
      @registry.RegistryOrigin::parse(value, allow_http=true).url()
    }),
  }
  let transport : PublishTransport = {
    plan,
    options,
    authorization: bearer_token.map(@registry.bearer_authorization),
    requests: 0,
    uploaded_bytes: 0L,
  }
  @async.with_timeout(options.total_timeout_ms, () => {
    transport.publish(expected_review)
  }) catch {
    @async.TimeoutError =>
      raise @model.IoFailure("registry publication exceeded its time budget")
    error => raise error
  }
}

///|
pub fn publication_receipt_json(receipt : PublicationReceipt) -> String {
  publication_receipt_value(receipt).stringify()
}

///|
pub fn publication_receipt_value(receipt : PublicationReceipt) -> Json {
  {
    "schema": "moonoci.registry-publication-receipt.v1",
    "root": Json::string(receipt.root.to_string()),
    "review_pin": Json::string(receipt.review_pin.to_string()),
    "requests": Json::number(receipt.requests.to_double()),
    "uploaded_blobs": Json::number(receipt.uploaded_blobs.to_double()),
    "reused_blobs": Json::number(receipt.reused_blobs.to_double()),
    "uploaded_manifests": Json::number(receipt.uploaded_manifests.to_double()),
    "reused_manifests": Json::number(receipt.reused_manifests.to_double()),
    "uploaded_bytes": Json::string(receipt.uploaded_bytes.to_string()),
    "tag_written": Json::boolean(receipt.tag_written),
  }
}
