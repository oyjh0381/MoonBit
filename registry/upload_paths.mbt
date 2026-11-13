///|
/// Begin an OCI Distribution monolithic POST/PUT blob upload.
pub fn blob_upload_path(
  repository : String,
) -> String raise @model.MoonOciError {
  validate_repository(repository)
  "/v2/" + repository + "/blobs/uploads/"
}

///|
fn validate_mount_source(
  repository : String,
  source : String,
) -> Unit raise @model.MoonOciError {
  validate_repository(source)
  if source == repository {
    raise @model.InvalidArgument(
      "blob mount source must differ from the destination repository",
    )
  }
}

///|
/// Request a mount from another repository on the destination Registry.
pub fn blob_mount_path(
  repository : String,
  source : String,
  digest : @model.Digest,
) -> String raise @model.MoonOciError {
  let endpoint = blob_upload_path(repository)
  validate_mount_source(repository, source)
  ignore(@model.Digest::parse(digest.to_string()))
  endpoint +
  "?mount=" +
  encode_query_value(digest.to_string()) +
  "&from=" +
  encode_query_value(source)
}

///|
fn valid_upload_id(id : StringView) -> Bool {
  if id.is_empty() || id == "." || id == ".." || id.length() > 255 {
    return false
  }
  for ch in id {
    if !name_character(ch) &&
      !(ch >= 'A' && ch <= 'Z') &&
      ch != '-' &&
      ch != '_' &&
      ch != '.' {
      return false
    }
  }
  true
}

///|
fn validate_upload_query(query : StringView) -> Unit raise @model.MoonOciError {
  if query.contains_char(';') {
    raise @model.InvalidOci("ambiguous OCI upload query separator")
  }
  for field in query.split("&") {
    let key = match field.find("=") {
      Some(i) => field[:i]
      None => field
    }
    if key.is_empty() || key.to_owned().to_lower() == "digest" {
      raise @model.InvalidOci("invalid OCI upload query parameter")
    }
    for ch in key {
      if !name_character(ch) &&
        !(ch >= 'A' && ch <= 'Z') &&
        ch != '_' &&
        ch != '-' &&
        ch != '.' {
        raise @model.InvalidOci("ambiguous OCI upload query parameter")
      }
    }
  }
}

///|
/// Use a server's upload session Location only within the original repository
/// and origin. Opaque query values are preserved and the digest is appended.
pub fn finalize_blob_upload(
  origin : RegistryOrigin,
  repository : String,
  status : Int32,
  headers : Array[@model.KeyValue],
  digest : @model.Digest,
) -> RegistryUrl raise @model.MoonOciError {
  let prefix = blob_upload_path(repository)
  ignore(@model.Digest::parse(digest.to_string()))
  if status != 202 {
    raise @model.IoFailure(
      "registry blob upload did not start: HTTP " + status.to_string(),
    )
  }
  guard single_header(headers, "location") is Some(location) else {
    raise @model.InvalidOci("registry blob upload lacks Location")
  }
  let session = origin.resolve(location, allow_http=origin.is_http())
  if !origin.same_origin(session.origin()) {
    raise @model.InvalidOci("registry blob upload leaves the original origin")
  }
  let target = session.path()
  let query_start = target.find("?")
  let path = match query_start {
    None => target[:]
    Some(index) => target[:index]
  }
  if !path.has_prefix(prefix) || !valid_upload_id(path[prefix.length():]) {
    raise @model.InvalidOci(
      "registry blob upload is outside the repository session endpoint",
    )
  }
  let delimiter = match query_start {
    None => "?"
    Some(index) => {
      validate_upload_query(target[index + 1:])
      "&"
    }
  }
  origin.request_url(
    target + delimiter + "digest=" + encode_query_value(digest.to_string()),
  )
}
