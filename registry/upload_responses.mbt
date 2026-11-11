///|
fn check_reported_digest(
  headers : Array[@model.KeyValue],
  expected : @model.Digest,
) -> Unit raise @model.MoonOciError {
  guard single_header(headers, "docker-content-digest") is Some(value) else {
    raise @model.InvalidOci("registry response lacks Docker-Content-Digest")
  }
  if @model.Digest::parse(value) != expected {
    raise @model.DigestMismatch("registry reported a different object digest")
  }
}

///|
/// Only reuse content whose HEAD response confirms both digest and size.
/// A 404 leaves the object to be uploaded. Other statuses fail publication.
pub fn publication_exists(
  status : Int32,
  headers : Array[@model.KeyValue],
  expected : PublishObject,
) -> Bool raise @model.MoonOciError {
  match status {
    404 => false
    200 => {
      check_reported_digest(headers, expected.digest)
      guard content_length(headers) is Some(size) else {
        raise @model.InvalidOci("registry HEAD response lacks Content-Length")
      }
      if size != expected.data.length().to_int64() {
        raise @model.SizeMismatch(
          "registry HEAD size differs from the publication object",
        )
      }
      true
    }
    _ =>
      raise @model.IoFailure(
        "registry publication HEAD returned HTTP " + status.to_string(),
      )
  }
}

///|
/// Check the digest acknowledged by a successful PUT. The returned Location
/// is a receipt field and is never used as another upload destination.
pub fn check_publication_written(
  status : Int32,
  headers : Array[@model.KeyValue],
  expected : @model.Digest,
) -> Unit raise @model.MoonOciError {
  if status != 201 {
    raise @model.IoFailure(
      "registry publication PUT returned HTTP " + status.to_string(),
    )
  }
  guard single_header(headers, "location") is Some(location) &&
    !location.is_empty() else {
    raise @model.InvalidOci("registry publication PUT lacks Location")
  }
  check_reported_digest(headers, expected)
}
