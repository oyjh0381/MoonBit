///|
pub(all) struct DiscoveryLimits {
  max_pages : Int32
  max_entries : Int32
  max_page_bytes : Int32
  max_total_bytes : Int64
}

///|
pub fn DiscoveryLimits::default() -> DiscoveryLimits {
  {
    max_pages: 64,
    max_entries: 4096,
    max_page_bytes: 1048576,
    max_total_bytes: 16777216L,
  }
}

///|
pub fn DiscoveryLimits::validate(
  self : DiscoveryLimits,
) -> Unit raise @model.MoonOciError {
  if self.max_pages < 1 ||
    self.max_pages > 1024 ||
    self.max_entries < 1 ||
    self.max_entries > 4096 ||
    self.max_page_bytes < 1 ||
    self.max_page_bytes > 16777216 ||
    self.max_total_bytes < 1L ||
    self.max_total_bytes > 268435456L {
    raise @model.InvalidArgument("invalid referrer discovery limits")
  }
}

///|
/// Transport-independent page walk. Exhaustion means the received Link chain
/// ended, never that the server disclosed every attachment in its repository.
pub struct ReferrerSession {
  priv origin : RegistryOrigin
  priv repository : String
  priv subject : @model.Digest
  priv artifact_type : String?
  priv limits : DiscoveryLimits
  priv paths : Map[String, Bool]
  priv advertised : Map[String, String]
  priv entries : Array[@artifacts.ReferrerAdvertisement]
  priv mut pending : String?
  priv mut pages : Int32
  priv mut received : Int64
}

///|
pub fn ReferrerSession::new(
  origin : RegistryOrigin,
  repository : String,
  subject : @model.Digest,
  artifact_type? : String,
  limits~ : DiscoveryLimits = DiscoveryLimits::default(),
) -> ReferrerSession raise @model.MoonOciError {
  limits.validate()
  let path = referrers_path(repository, subject, artifact_type?)
  {
    origin,
    repository,
    subject,
    artifact_type,
    limits,
    paths: Map([(path, true)]),
    advertised: Map([]),
    entries: [],
    pending: Some(path),
    pages: 0,
    received: 0L,
  }
}

///|
pub fn ReferrerSession::next_path(self : ReferrerSession) -> String? {
  self.pending
}

///|
pub fn ReferrerSession::body_limit(
  self : ReferrerSession,
) -> Int32 raise @model.MoonOciError {
  if self.pending is None {
    raise @model.InvalidArgument("referrer discovery has no pending page")
  }
  let remaining = self.limits.max_total_bytes - self.received
  if remaining < 1L {
    raise @model.ResourceLimitExceeded(
      "referrer discovery byte quota exhausted",
    )
  }
  if remaining < self.limits.max_page_bytes.to_int64() {
    remaining.to_int()
  } else {
    self.limits.max_page_bytes
  }
}

///|
pub fn ReferrerSession::pages(self : ReferrerSession) -> Int32 {
  self.pages
}

///|
pub fn ReferrerSession::received_bytes(self : ReferrerSession) -> Int64 {
  self.received
}

///|
/// Validate an entire page/next link before changing state. Repeated identical
/// advertisements are deduplicated; conflicting metadata for one pin is refused.
pub fn ReferrerSession::accept(
  self : ReferrerSession,
  status : Int32,
  headers : Array[@model.KeyValue],
  body : Bytes,
) -> Unit raise @model.MoonOciError {
  check_response_head(status, headers, self.body_limit())
  if manifest_media_type(headers) != @model.media_type_index {
    raise @model.InvalidOci("referrers response must be an OCI index")
  }
  if body.length() > self.body_limit() ||
    (match content_length(headers) {
      Some(length) => length != body.length().to_int64()
      None => false
    }) {
    raise @model.SizeMismatch(
      "referrer page length exceeds quota or declared length",
    )
  }
  if single_header(headers, "docker-content-digest") is Some(value) {
    if @model.Digest::parse(value) != @digest.sha256(body) {
      raise @model.DigestMismatch(
        "referrer page digest header disagrees with bytes",
      )
    }
  }
  let page = @artifacts.decode_referrer_page(
    body,
    max_entries=self.limits.max_entries,
  )
  let next = referrer_next_path(
    self.origin,
    self.repository,
    self.subject,
    headers,
    artifact_type?=self.artifact_type,
  )
  if next is Some(path) {
    if self.paths.contains(path) {
      raise @model.InvalidOci("referrer pagination repeats a requested URL")
    }
    if self.pages + 1 == self.limits.max_pages {
      raise @model.ResourceLimitExceeded(
        "referrer pagination exceeds page quota",
      )
    }
  }
  let added : Array[(@artifacts.ReferrerAdvertisement, String)] = []
  for entry in page {
    if entry.descriptor.media_type != @model.media_type_manifest &&
      entry.descriptor.media_type != @model.media_type_index {
      raise @model.Unsupported(
        "referrer descriptor is not an OCI manifest/index",
      )
    }
    let key = entry.descriptor.digest.to_string()
    let fingerprint = @codec.encode_descriptor(entry.descriptor) +
      "|" +
      entry.artifact_type.unwrap_or("")
    match self.advertised.get(key) {
      Some(previous) if previous != fingerprint =>
        raise @model.InvalidOci(
          "conflicting referrer advertisements for one digest",
        )
      Some(_) => ()
      None => added.push((entry, fingerprint))
    }
  }
  if self.advertised.length() + added.length() > self.limits.max_entries {
    raise @model.ResourceLimitExceeded("referrer advertisement quota exceeded")
  }
  for (entry, fingerprint) in added {
    self.advertised[entry.descriptor.digest.to_string()] = fingerprint
    // Servers may ignore artifactType. Filter locally after budgeting all ads.
    if self.artifact_type is None || self.artifact_type == entry.artifact_type {
      self.entries.push(entry)
    }
  }
  self.pages += 1
  self.received += body.length().to_int64()
  self.pending = next
  if next is Some(path) {
    self.paths[path] = true
  }
}

///|
pub fn ReferrerSession::advertisements(
  self : ReferrerSession,
) -> Array[@artifacts.ReferrerAdvertisement] raise @model.MoonOciError {
  if self.pending is Some(_) {
    raise @model.InvalidArgument("referrer listing has unfinished pages")
  }
  self.entries.map(entry => {
    ..entry,
    descriptor: {
      ..entry.descriptor,
      annotations: entry.descriptor.annotations.copy(),
    },
  })
}

///|
pub fn ReferrerSession::report(
  self : ReferrerSession,
) -> Json raise @model.MoonOciError {
  let entries = self
    .advertisements()
    .map(entry => {
      let descriptor = @codec.parse_json_document(
        @utf8.encode(@codec.encode_descriptor(entry.descriptor)),
      )
      match descriptor {
        Object(fields) => {
          if entry.artifact_type is Some(value) {
            fields["artifactType"] = Json::string(value)
          }
          Json::object(fields)
        }
        _ => abort("encoded descriptor is an object")
      }
    })
  {
    "schema": Json::string("moonoci.registry-referrers.v1"),
    "subject": Json::string(self.subject.to_string()),
    "pages": Json::number(self.pages.to_double()),
    "listing_bytes": Json::string(self.received.to_string()),
    "listing_exhausted": Json::boolean(true),
    "manifests_verified": Json::boolean(false),
    "referrers": Json::array(entries),
  }
}
