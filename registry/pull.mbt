///|
pub(all) struct PullLimits {
  max_objects : Int32
  max_visits : Int32
  max_depth : Int32
  max_metadata_bytes : Int32
  max_blob_bytes : Int32
  max_total_bytes : Int64
}

///|
pub fn PullLimits::default() -> PullLimits {
  {
    max_objects: 4096,
    max_visits: 16384,
    max_depth: 32,
    max_metadata_bytes: 16777216,
    max_blob_bytes: 67108864,
    max_total_bytes: 536870912L,
  }
}

///|
pub fn PullLimits::validate(
  self : PullLimits,
) -> Unit raise @model.MoonOciError {
  if self.max_objects < 1 ||
    self.max_objects > 65536 ||
    self.max_visits < 1 ||
    self.max_visits > 100000 ||
    self.max_depth < 1 ||
    self.max_depth > 128 ||
    self.max_metadata_bytes < 1 ||
    self.max_metadata_bytes > 16777216 ||
    self.max_blob_bytes < 1 ||
    self.max_blob_bytes > 536870912 ||
    self.max_total_bytes < 1L ||
    self.max_total_bytes > 8589934592L {
    raise @model.InvalidArgument("invalid registry pull resource limits")
  }
}

///|
/// An observation for a host transport. Acceptance always uses the private
/// queued request; altering a returned observation cannot alter session state.
pub(all) struct FetchRequest {
  path : String
  kind : String
  digest : @model.Digest
  size : Int64?
  media_type : String?
  depth : Int32
}

///|
priv struct Dependency {
  descriptor : @model.Descriptor
  kind : String
  depth : Int32
}

///|
pub struct PullSession {
  priv repository : String
  priv reference : String
  priv limits : PullLimits
  priv include_subjects : Bool
  priv queue : Array[FetchRequest]
  priv scheduled : Map[String, Bool]
  priv sizes : Map[String, Int64]
  priv media : Map[String, String]
  priv content : @layout.MemoryLayout
  priv mut cursor : Int32
  priv mut reserved : Int64
  priv mut visits : Int32
  priv mut accepted_bytes : Int64
  priv mut cached_bytes : Int64
  priv mut cached_requests : Int32
  priv mut root : @model.Descriptor?
}

///|
pub fn PullSession::new(
  repository : String,
  reference : String,
  expected : @model.Digest,
  limits~ : PullLimits = PullLimits::default(),
  include_subjects~ : Bool = false,
) -> PullSession raise @model.MoonOciError {
  limits.validate()
  let path = manifest_path(repository, reference)
  ignore(@model.Digest::parse(expected.to_string()))
  if reference.contains(":") && @model.Digest::parse(reference) != expected {
    raise @model.DigestMismatch(
      "registry reference disagrees with caller root pin",
    )
  }
  let request : FetchRequest = {
    path,
    kind: "manifest",
    digest: expected,
    size: None,
    media_type: None,
    depth: 1,
  }
  {
    repository,
    reference,
    limits,
    include_subjects,
    queue: [request],
    scheduled: Map([("manifest|" + expected.to_string(), true)]),
    sizes: Map([]),
    media: Map([]),
    content: @layout.MemoryLayout::new(),
    cursor: 0,
    reserved: 0L,
    visits: 1,
    accepted_bytes: 0L,
    cached_bytes: 0L,
    cached_requests: 0,
    root: None,
  }
}

///|
pub fn PullSession::next(self : PullSession) -> FetchRequest? {
  if self.cursor == self.queue.length() {
    None
  } else {
    Some(self.queue[self.cursor])
  }
}

///|
pub fn PullSession::accepted_requests(self : PullSession) -> Int32 {
  self.cursor
}

///|
pub fn PullSession::planned_requests(self : PullSession) -> Int32 {
  self.queue.length()
}

///|
pub fn PullSession::accepted_bytes(self : PullSession) -> Int64 {
  self.accepted_bytes
}

///|
pub fn PullSession::reserved_bytes(self : PullSession) -> Int64 {
  self.reserved
}

///|
pub fn PullSession::body_limit(
  self : PullSession,
) -> Int32 raise @model.MoonOciError {
  let request = match self.next() {
    Some(request) => request
    None => raise @model.InvalidArgument("pull has no pending request")
  }
  let limit = if request.kind == "manifest" {
    self.limits.max_metadata_bytes
  } else {
    self.limits.max_blob_bytes
  }
  if self.limits.max_total_bytes < limit.to_int64() {
    self.limits.max_total_bytes.to_int()
  } else {
    limit
  }
}

///|
fn dependencies(
  descriptor : @model.Descriptor,
  body : Bytes,
  depth : Int32,
  include_subjects : Bool,
) -> Array[Dependency] raise @model.MoonOciError {
  let result = []
  if descriptor.media_type == @model.media_type_index {
    for child in @codec.decode_index(body).manifests {
      result.push({ descriptor: child, kind: "manifest", depth: depth + 1, })
    }
  } else {
    let manifest = @codec.decode_manifest(body)
    for child in [manifest.config] + manifest.layers {
      result.push({ descriptor: child, kind: "blob", depth, })
    }
  }
  if include_subjects {
    let fields = match @codec.parse_json_document(body) {
      Object(fields) => fields
      _ => raise @model.InvalidOci("manifest must be an object")
    }
    if fields.get("subject") is Some(value) {
      result.push({
        descriptor: @codec.decode_descriptor(value),
        kind: "manifest",
        depth: depth + 1,
      })
    }
  }
  result
}

///|
/// Verify and stage a response atomically: bad metadata, quota or HTTP checks
/// leave cursor, content and dependency reservations unchanged for host retry.
pub fn PullSession::accept(
  self : PullSession,
  status : Int32,
  headers : Array[@model.KeyValue],
  body : Bytes,
) -> Unit raise @model.MoonOciError {
  let request = match self.next() {
    Some(request) => request
    None => raise @model.InvalidArgument("pull has no pending response")
  }
  let max_bytes = self.body_limit()
  let descriptor = if request.kind == "manifest" {
    let expected_size = request.size
    let expected_media = request.media_type
    verify_manifest_response(
      status,
      headers,
      body,
      request.digest,
      max_bytes~,
      expected_size?,
      expected_media?,
    )
  } else {
    let expected : @model.Descriptor = {
      media_type: request.media_type.unwrap_or("application/octet-stream"),
      digest: request.digest,
      size: request.size.unwrap_or(-1L),
      annotations: [],
      platform: None,
    }
    verify_blob_response(status, headers, body, expected, max_bytes~)
    expected
  }
  let seeds = if request.kind == "manifest" {
    dependencies(descriptor, body, request.depth, self.include_subjects)
  } else {
    []
  }
  if seeds.length() > self.limits.max_visits - self.visits {
    raise @model.ResourceLimitExceeded("pull descriptor visit quota exceeded")
  }
  let sizes : Map[String, Int64] = Map([])
  let media : Map[String, String] = Map([])
  let scheduled : Map[String, Bool] = Map([])
  let pending : Array[FetchRequest] = []
  let mut reserved = self.reserved
  let current = descriptor.digest.to_string()
  if !self.sizes.contains(current) {
    if descriptor.size > self.limits.max_total_bytes - reserved {
      raise @model.ResourceLimitExceeded(
        "root content exceeds total pull byte quota",
      )
    }
    sizes[current] = descriptor.size
    reserved += descriptor.size
  }
  if request.kind == "manifest" {
    media[current] = descriptor.media_type
  }
  for seed in seeds {
    let child = seed.descriptor
    let key = child.digest.to_string()
    ignore(@model.Digest::parse(key))
    let limit = if seed.kind == "manifest" {
      self.limits.max_metadata_bytes
    } else {
      self.limits.max_blob_bytes
    }
    if child.size < 0L ||
      child.size > limit.to_int64() ||
      (seed.kind == "manifest" && seed.depth > self.limits.max_depth) {
      raise @model.ResourceLimitExceeded("pull child exceeds size/depth quota")
    }
    if seed.kind == "manifest" {
      if child.media_type != @model.media_type_index &&
        child.media_type != @model.media_type_manifest {
        raise @model.Unsupported(
          "index/subject metadata is outside the OCI pull profile",
        )
      }
      let previous = match media.get(key) {
        Some(value) => Some(value)
        None => self.media.get(key)
      }
      if previous is Some(value) {
        if value != child.media_type {
          raise @model.InvalidOci(
            "conflicting manifest media types for one digest",
          )
        }
      }
      media[key] = child.media_type
    }
    let known = match sizes.get(key) {
      Some(value) => Some(value)
      None => self.sizes.get(key)
    }
    match known {
      Some(size) =>
        if size != child.size {
          raise @model.SizeMismatch(
            "repeated pull descriptor has inconsistent size",
          )
        }
      None => {
        if child.size > self.limits.max_total_bytes - reserved {
          raise @model.ResourceLimitExceeded(
            "declared pull closure exceeds total byte quota",
          )
        }
        sizes[key] = child.size
        reserved += child.size
      }
    }
    let task = seed.kind + "|" + key
    if !self.scheduled.contains(task) && !scheduled.contains(task) {
      let path = if seed.kind == "manifest" {
        manifest_path(self.repository, key)
      } else {
        blob_path(self.repository, child.digest)
      }
      pending.push({
        path,
        kind: seed.kind,
        digest: child.digest,
        size: Some(child.size),
        media_type: Some(child.media_type),
        depth: seed.depth,
      })
      scheduled[task] = true
    }
  }
  if self.sizes.length() + sizes.length() > self.limits.max_objects ||
    self.queue.length() + pending.length() > self.limits.max_visits {
    raise @model.ResourceLimitExceeded("pull object/request quota exceeded")
  }
  // All semantic/header/quota checks above are pure. Bytes and metadata do not
  // escape until finish. put_blob rejects inconsistent SHA collisions itself.
  ignore(self.content.put_blob(descriptor.media_type, body))
  for key, size in sizes {
    self.sizes[key] = size
  }
  for key, value in media {
    self.media[key] = value
  }
  for key, value in scheduled {
    self.scheduled[key] = value
  }
  self.queue.append(pending)
  self.reserved = reserved
  self.visits += seeds.length()
  self.accepted_bytes += body.length().to_int64()
  if self.cursor == 0 {
    self.root = Some(descriptor)
  }
  self.cursor += 1
}

///|
/// Produce a separate supported-profile verified layout. The original root
/// index bytes are preserved; a manifest root receives a new layout wrapper.
pub fn PullSession::finish(
  self : PullSession,
) -> @layout.MemoryLayout raise @model.MoonOciError {
  if self.cursor != self.queue.length() {
    raise @model.InvalidOci("registry pull is incomplete")
  }
  let root = match self.root {
    Some(value) => value
    None => raise @model.InvalidOci("registry root has not been accepted")
  }
  let index = if root.media_type == @model.media_type_index {
    self.content.require_blob(root)
  } else {
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests: [
        {
          ..root,
          annotations: [
            { key: @model.annotation_ref_name, value: self.reference, },
          ],
        },
      ],
      annotations: [],
    })
  }
  let records = self.content
    .blob_records()
    .filter(blob => {
      root.media_type != @model.media_type_index ||
      blob.descriptor().digest != root.digest ||
      self.scheduled.contains("blob|" + root.digest.to_string())
    })
    .map(blob => (blob.descriptor(), blob.data()))
  let result = @layout.MemoryLayout::from_untrusted_parts(
    self.content.marker(),
    index,
    records,
  )
  let verification = @artifacts.verify_store(
    result,
    graph_limits={
      max_depth: self.limits.max_depth,
      max_visits: self.limits.max_visits,
      max_metadata_bytes: self.limits.max_total_bytes,
    },
    max_total_payload_bytes=self.limits.max_total_bytes,
  )
  if !verification.valid || !verification.complete {
    raise @model.InvalidOci(
      "downloaded layout fails supported image/artifact semantic verification",
    )
  }
  result
}
