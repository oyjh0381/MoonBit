///|
fn name_character(ch : Char) -> Bool {
  (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')
}

///|
/// OCI Distribution 1.1.1 repository-name grammar, with a library quota of 255
/// ASCII bytes. Origin and repository are separate; no URL unescaping is done.
pub fn validate_repository(name : String) -> Unit raise @model.MoonOciError {
  if name.is_empty() || name.length() > 255 {
    raise @model.InvalidArgument(
      "registry repository must contain 1..255 ASCII characters",
    )
  }
  for part in name.split("/") {
    let chars = part.to_owned().to_array()
    let mut index = 0
    if chars.is_empty() {
      raise @model.InvalidArgument("empty repository path component")
    }
    while index < chars.length() {
      if !name_character(chars[index]) {
        raise @model.InvalidArgument("invalid repository name component")
      }
      while index < chars.length() && name_character(chars[index]) {
        index += 1
      }
      if index == chars.length() {
        break
      }
      match chars[index] {
        '.' => index += 1
        '_' => {
          index += 1
          if index < chars.length() && chars[index] == '_' {
            index += 1
          }
        }
        '-' =>
          while index < chars.length() && chars[index] == '-' {
            index += 1
          }
        _ => raise @model.InvalidArgument("invalid repository separator")
      }
      if index == chars.length() {
        raise @model.InvalidArgument(
          "repository component ends with a separator",
        )
      }
    }
  }
}

///|
/// Tags follow the Distribution grammar. Digests use this library's SHA-256
/// profile. No implicit latest tag, percent-decoding or hostname inference.
pub fn validate_reference(reference : String) -> Unit raise @model.MoonOciError {
  if reference.contains(":") {
    ignore(@model.Digest::parse(reference))
    return
  }
  if reference.is_empty() || reference.length() > 128 {
    raise @model.InvalidArgument(
      "registry tag must contain 1..128 ASCII characters",
    )
  }
  let mut first = true
  for ch in reference {
    let alnum = name_character(ch) || (ch >= 'A' && ch <= 'Z')
    if !alnum && ch != '_' && (first || (ch != '.' && ch != '-')) {
      raise @model.InvalidArgument("invalid registry tag character")
    }
    first = false
  }
}

///|
pub fn manifest_path(
  repository : String,
  reference : String,
) -> String raise @model.MoonOciError {
  validate_repository(repository)
  validate_reference(reference)
  "/v2/" + repository + "/manifests/" + reference
}

///|
pub fn blob_path(
  repository : String,
  digest : @model.Digest,
) -> String raise @model.MoonOciError {
  validate_repository(repository)
  ignore(@model.Digest::parse(digest.to_string()))
  "/v2/" + repository + "/blobs/" + digest.to_string()
}

///|
/// UTF-8 query encoding for one value. Reserved characters never form a new
/// parameter; spaces use %20, not application/x-www-form-urlencoded '+'.
pub fn encode_query_value(value : String) -> String {
  let output = StringBuilder()
  let digits = "0123456789ABCDEF".to_array()
  for byte in @utf8.encode(value) {
    let n = byte.to_int()
    if (n >= 65 && n <= 90) ||
      (n >= 97 && n <= 122) ||
      (n >= 48 && n <= 57) ||
      [45, 46, 95, 126].contains(n) {
      output.write_char(n.to_char().unwrap())
    } else {
      output.write_char('%')
      output.write_char(digits[n / 16])
      output.write_char(digits[n % 16])
    }
  }
  output.to_string()
}

///|
pub fn referrers_path(
  repository : String,
  subject : @model.Digest,
  artifact_type? : String,
) -> String raise @model.MoonOciError {
  validate_repository(repository)
  ignore(@model.Digest::parse(subject.to_string()))
  let base = "/v2/" + repository + "/referrers/" + subject.to_string()
  match artifact_type {
    None => base
    Some(value) => {
      @artifacts.validate_media_type(value)
      base + "?artifactType=" + encode_query_value(value)
    }
  }
}

///|
pub fn tags_path(
  repository : String,
  count~ : Int32 = 100,
  last? : String,
) -> String raise @model.MoonOciError {
  validate_repository(repository)
  if count < 1 || count > 1000 {
    raise @model.InvalidArgument("registry tag page size must be in 1..1000")
  }
  let path = "/v2/" + repository + "/tags/list?n=" + count.to_string()
  match last {
    None => path
    Some(tag) => {
      validate_reference(tag)
      if tag.contains(":") {
        raise @model.InvalidArgument("last tag cannot be a digest")
      }
      path + "&last=" + encode_query_value(tag)
    }
  }
}

///|
pub fn manifest_headers() -> Array[@model.KeyValue] {
  [
    {
      key: "Accept",
      value: @model.media_type_index + ", " + @model.media_type_manifest,
    },
    { key: "Accept-Encoding", value: "identity", },
  ]
}
