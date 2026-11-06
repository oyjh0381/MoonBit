///|
fn header_token(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') ||
  (ch >= 'A' && ch <= 'Z') ||
  (ch >= '0' && ch <= '9') ||
  "!#$%&'*+-.^_`|~".contains_char(ch)
}

///|
/// Bounded, case-insensitive lookup. Duplicate critical fields are refused,
/// including differently cased names; a transport must preserve or combine
/// duplicate wire fields rather than silently discarding them.
pub fn single_header(
  headers : Array[@model.KeyValue],
  name : String,
) -> String? raise @model.MoonOciError {
  if headers.length() > 128 {
    raise @model.ResourceLimitExceeded(
      "registry response exceeds 128 represented headers",
    )
  }
  let mut total = 0
  let mut result = None
  for header in headers {
    if header.key.is_empty() ||
      header.key.length() > 256 ||
      header.value.length() > 8192 {
      raise @model.ResourceLimitExceeded(
        "registry response header length quota exceeded",
      )
    }
    total += header.key.length() + header.value.length()
    if total > 65536 {
      raise @model.ResourceLimitExceeded(
        "registry response header quota exceeded",
      )
    }
    for ch in header.key {
      if !header_token(ch) {
        raise @model.InvalidOci("invalid response header name")
      }
    }
    for ch in header.value {
      if (ch < ' ' && ch != '\t') || ch == '\u{007f}' {
        raise @model.InvalidOci("invalid response header control character")
      }
    }
    if header.key.to_lower() == name.to_lower() {
      if result is Some(_) {
        raise @model.InvalidOci("duplicate critical response header")
      }
      result = Some(header.value.trim(chars=" \t").to_owned())
    }
  }
  result
}

///|
pub fn content_length(
  headers : Array[@model.KeyValue],
) -> Int64? raise @model.MoonOciError {
  match single_header(headers, "content-length") {
    None => None
    Some(value) => {
      if value.is_empty() {
        raise @model.InvalidOci("empty response Content-Length")
      }
      for ch in value {
        if ch < '0' || ch > '9' {
          raise @model.InvalidOci(
            "response Content-Length must be non-negative decimal",
          )
        }
      }
      let length = @string.parse_int64(value) catch {
        _ =>
          raise @model.ResourceLimitExceeded(
            "response Content-Length overflows Int64",
          )
      }
      Some(length)
    }
  }
}

///|
/// Pre-read checks for bounded transports. identity applies to HTTP encoding,
/// not to an OCI layer's independent gzip media type.
pub fn check_response_head(
  status : Int32,
  headers : Array[@model.KeyValue],
  max_bytes : Int32,
  expected_size? : Int64,
) -> Unit raise @model.MoonOciError {
  if max_bytes < 1 || max_bytes > 536870912 {
    raise @model.InvalidArgument("response body limit must be in 1..512 MiB")
  }
  if status != 200 {
    raise @model.IoFailure(
      "registry request returned HTTP " + status.to_string(),
    )
  }
  if single_header(headers, "content-encoding") is Some(encoding) {
    if encoding.to_lower() != "identity" {
      raise @model.Unsupported(
        "HTTP content encoding must be identity for pinned content",
      )
    }
  }
  if expected_size is Some(size) {
    if size < 0L || size > max_bytes.to_int64() {
      raise @model.ResourceLimitExceeded(
        "expected response size exceeds the body quota",
      )
    }
  }
  if content_length(headers) is Some(length) {
    if length > max_bytes.to_int64() {
      raise @model.ResourceLimitExceeded(
        "declared response body exceeds byte quota",
      )
    }
    if expected_size is Some(size) {
      if length != size {
        raise @model.SizeMismatch(
          "response Content-Length disagrees with descriptor",
        )
      }
    }
  }
}

///|
fn verify_content(
  status : Int32,
  headers : Array[@model.KeyValue],
  body : Bytes,
  expected : @model.Digest,
  max_bytes : Int32,
  expected_size : Int64?,
) -> Unit raise @model.MoonOciError {
  ignore(@model.Digest::parse(expected.to_string()))
  match expected_size {
    Some(size) =>
      check_response_head(status, headers, max_bytes, expected_size=size)
    None => check_response_head(status, headers, max_bytes)
  }
  if body.length() > max_bytes {
    raise @model.ResourceLimitExceeded(
      "actual response body exceeds byte quota",
    )
  }
  if content_length(headers) is Some(length) {
    if length != body.length().to_int64() {
      raise @model.SizeMismatch(
        "actual response length differs from Content-Length",
      )
    }
  }
  if expected_size is Some(size) {
    if size != body.length().to_int64() {
      raise @model.SizeMismatch(
        "actual response length differs from descriptor",
      )
    }
  }
  let actual = @digest.sha256(body)
  if actual != expected {
    raise @model.DigestMismatch(
      "registry content does not match the caller's expected digest",
    )
  }
  if single_header(headers, "docker-content-digest") is Some(value) {
    if @model.Digest::parse(value) != actual {
      raise @model.DigestMismatch(
        "registry Docker-Content-Digest disagrees with response bytes",
      )
    }
  }
}

///|
pub fn manifest_media_type(
  headers : Array[@model.KeyValue],
) -> String raise @model.MoonOciError {
  let value = match single_header(headers, "content-type") {
    Some(value) => value
    None => raise @model.InvalidOci("manifest response requires Content-Type")
  }
  let media = value.split(";").collect()[0]
    .trim(chars=" \t")
    .to_owned()
    .to_lower()
  if media != @model.media_type_index && media != @model.media_type_manifest {
    raise @model.Unsupported(
      "manifest Content-Type is outside the OCI pull profile",
    )
  }
  media
}

///|
/// Verify exact wire entity bytes and optional digest header, then validate the
/// selected manifest/index structure. This is not layer/consumer verification.
pub fn verify_manifest_response(
  status : Int32,
  headers : Array[@model.KeyValue],
  body : Bytes,
  expected : @model.Digest,
  max_bytes~ : Int32 = 16777216,
  expected_size? : Int64,
  expected_media? : String,
) -> @model.Descriptor raise @model.MoonOciError {
  verify_content(status, headers, body, expected, max_bytes, expected_size)
  let media_type = manifest_media_type(headers)
  if expected_media is Some(media) {
    if media != media_type {
      raise @model.InvalidOci(
        "manifest response media type differs from the requested descriptor",
      )
    }
  }
  if media_type == @model.media_type_index {
    let index = @codec.decode_index(body)
    if index.schema_version != 2 || index.media_type != media_type {
      raise @model.InvalidOci(
        "manifest body disagrees with Content-Type or schema",
      )
    }
  } else {
    let manifest = @codec.decode_manifest(body)
    if manifest.schema_version != 2 || manifest.media_type != media_type {
      raise @model.InvalidOci(
        "manifest body disagrees with Content-Type or schema",
      )
    }
  }
  {
    media_type,
    digest: expected,
    size: body.length().to_int64(),
    annotations: [],
    platform: None,
  }
}

///|
/// Config/layer/artifact payload bytes remain opaque. Their declared media type
/// need not match HTTP Content-Type; exact size and digest are authoritative.
pub fn verify_blob_response(
  status : Int32,
  headers : Array[@model.KeyValue],
  body : Bytes,
  expected : @model.Descriptor,
  max_bytes~ : Int32 = 268435456,
) -> Unit raise @model.MoonOciError {
  verify_content(
    status,
    headers,
    body,
    expected.digest,
    max_bytes,
    Some(expected.size),
  )
}
