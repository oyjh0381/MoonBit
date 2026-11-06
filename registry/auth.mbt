///|
pub struct BearerChallenge {
  priv realm : String
  priv service : String?
}

///|
fn skip_ows(chars : Array[Char], start : Int32) -> Int32 {
  let mut index = start
  while index < chars.length() && (chars[index] == ' ' || chars[index] == '\t') {
    index += 1
  }
  index
}

///|
/// A single Bearer challenge with token/quoted-string parameters. Quoted commas
/// and escaped quotes do not terminate a parameter; duplicate names fail closed.
pub fn parse_bearer_challenge(
  input : String,
) -> BearerChallenge raise @model.MoonOciError {
  if input.length() > 8192 {
    raise @model.ResourceLimitExceeded("Bearer challenge exceeds header quota")
  }
  let chars = input.to_array()
  let mut index = skip_ows(chars, 0)
  let start = index
  while index < chars.length() && header_token(chars[index]) {
    index += 1
  }
  let scheme = String::from_array(chars[start:index].to_owned()).to_lower()
  if scheme != "bearer" {
    raise @model.Unsupported(
      "registry requires an unsupported authentication scheme",
    )
  }
  if index == chars.length() || (chars[index] != ' ' && chars[index] != '\t') {
    raise @model.InvalidOci("Bearer challenge requires parameters")
  }
  let fields : Map[String, String] = Map([])
  index = skip_ows(chars, index)
  while index < chars.length() {
    let start = index
    while index < chars.length() && header_token(chars[index]) {
      index += 1
    }
    if start == index {
      raise @model.InvalidOci("invalid Bearer parameter name")
    }
    let name = String::from_array(chars[start:index].to_owned()).to_lower()
    if fields.contains(name) {
      raise @model.InvalidOci("duplicate Bearer parameter")
    }
    index = skip_ows(chars, index)
    if index == chars.length() || chars[index] != '=' {
      raise @model.InvalidOci("Bearer parameter requires equals")
    }
    index = skip_ows(chars, index + 1)
    if index == chars.length() {
      raise @model.InvalidOci("missing Bearer parameter value")
    }
    let output = StringBuilder()
    if chars[index] == '"' {
      index += 1
      let mut closed = false
      while index < chars.length() {
        let ch = chars[index]
        index += 1
        if ch == '"' {
          closed = true
          break
        }
        let ch = if ch == '\\' {
          if index == chars.length() {
            raise @model.InvalidOci("incomplete Bearer quoted escape")
          }
          let value = chars[index]
          index += 1
          value
        } else {
          ch
        }
        if (ch < ' ' && ch != '\t') || ch == '\u{007f}' {
          raise @model.InvalidOci("control character in Bearer parameter")
        }
        output.write_char(ch)
      }
      if !closed {
        raise @model.InvalidOci("unterminated Bearer quoted value")
      }
    } else {
      let start = index
      while index < chars.length() && header_token(chars[index]) {
        output.write_char(chars[index])
        index += 1
      }
      if index == start {
        raise @model.InvalidOci("invalid Bearer token parameter")
      }
    }
    fields[name] = output.to_string()
    index = skip_ows(chars, index)
    if index < chars.length() {
      if chars[index] != ',' {
        raise @model.InvalidOci("invalid Bearer parameter delimiter")
      }
      index = skip_ows(chars, index + 1)
      if index == chars.length() {
        raise @model.InvalidOci("trailing Bearer parameter delimiter")
      }
    }
  }
  let realm = match fields.get("realm") {
    Some(value) if !value.is_empty() => value
    _ => raise @model.InvalidOci("Bearer challenge requires a nonempty realm")
  }
  if realm.length() > 2048 {
    raise @model.ResourceLimitExceeded("Bearer realm exceeds URL quota")
  }
  if fields.get("service") is Some(value) {
    if value.length() > 1024 {
      raise @model.ResourceLimitExceeded("Bearer service exceeds quota")
    }
  }
  { realm, service: fields.get("service"), }
}

///|
pub fn BearerChallenge::realm(self : BearerChallenge) -> String {
  self.realm
}

///|
fn hex_value(byte : Byte) -> Int32 {
  let n = byte.to_int()
  if n >= 48 && n <= 57 {
    n - 48
  } else if n >= 65 && n <= 70 {
    n - 55
  } else if n >= 97 && n <= 102 {
    n - 87
  } else {
    -1
  }
}

///|
fn decode_query_name(value : String) -> String raise @model.MoonOciError {
  let bytes = @utf8.encode(value)
  let output = []
  let mut index = 0
  while index < bytes.length() {
    if bytes[index] == b'%' {
      if index + 2 >= bytes.length() {
        raise @model.InvalidOci("incomplete realm query escape")
      }
      let first = hex_value(bytes[index + 1])
      let second = hex_value(bytes[index + 2])
      if first < 0 || second < 0 {
        raise @model.InvalidOci("invalid realm query escape")
      }
      output.push((first * 16 + second).to_byte())
      index += 3
    } else {
      output.push(if bytes[index] == b'+' { b' ' } else { bytes[index] })
      index += 1
    }
  }
  @utf8.decode(Bytes::from_array(output)) catch {
    _ => raise @model.InvalidOci("realm query name is not UTF-8")
  }
}

///|
/// Build an anonymous pull-token request. The server's broader scope is never
/// copied: scope always comes from the caller's validated repository and pull.
/// Cross-origin realms require a caller allowlist; HTTPS cannot downgrade.
pub fn BearerChallenge::token_request(
  self : BearerChallenge,
  registry : RegistryOrigin,
  repository : String,
  allowed_realms~ : Array[RegistryOrigin] = [],
  allow_http~ : Bool = false,
) -> RegistryUrl raise @model.MoonOciError {
  validate_repository(repository)
  let realm = RegistryUrl::parse(self.realm, allow_http~)
  if !registry.is_http() && realm.origin().is_http() {
    raise @model.InvalidArgument("Bearer realm cannot downgrade HTTPS to HTTP")
  }
  if !registry.same_origin(realm.origin()) &&
    !allowed_realms.any(origin => origin.same_origin(realm.origin())) {
    raise @model.InvalidArgument(
      "cross-origin Bearer realm is not explicitly allowed",
    )
  }
  let path = realm.path()
  if path.contains(";") {
    raise @model.InvalidOci(
      "realm URL cannot contain ambiguous semicolon parameters",
    )
  }
  if path.find("?") is Some(start) {
    let query = path[start + 1:]
    let names : Map[String, Bool] = Map([])
    if !query.is_empty() {
      for pair in query.split("&") {
        let name = decode_query_name(pair.split("=").collect()[0].to_owned()).to_lower()
        if name.is_empty() ||
          names.contains(name) ||
          ["scope", "service", "offline_token", "client_id"].contains(name) {
          raise @model.InvalidOci(
            "realm URL contains duplicate or reserved token parameters",
          )
        }
        names[name] = true
      }
    }
  }
  let delimiter = if !path.contains("?") {
    "?"
  } else if path.has_suffix("?") {
    ""
  } else {
    "&"
  }
  let parameters = []
  if self.service is Some(service) {
    parameters.push("service=" + encode_query_value(service))
  }
  parameters.push(
    "scope=" + encode_query_value("repository:" + repository + ":pull"),
  )
  realm.origin().request_url(path + delimiter + parameters.join("&"))
}

///|
/// Reject controls and non-token68 values before putting a secret in a header.
pub fn bearer_authorization(token : String) -> String raise @model.MoonOciError {
  if token.is_empty() || token.length() > 16384 {
    raise @model.InvalidArgument("Bearer token length is outside quota")
  }
  let mut padding = false
  let mut characters = 0
  for ch in token {
    if ch == '=' {
      padding = true
      continue
    }
    if padding ||
      !((ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      "-._~+/".contains_char(ch)) {
      raise @model.InvalidArgument(
        "Bearer token contains an invalid header character",
      )
    }
    characters += 1
  }
  if characters == 0 {
    raise @model.InvalidArgument("Bearer token has no token68 content")
  }
  "Bearer " + token
}

///|
pub fn decode_bearer_token(input : Bytes) -> String raise @model.MoonOciError {
  if input.length() > 65536 {
    raise @model.ResourceLimitExceeded("Bearer token response exceeds 64 KiB")
  }
  let fields = match @codec.parse_json_document(input) {
    Object(fields) => fields
    _ => raise @model.InvalidJson("Bearer token response must be an object")
  }
  let token = match fields.get("token") {
    None => None
    Some(String(value)) => Some(value)
    _ => raise @model.InvalidJson("Bearer token must be a string")
  }
  let access_token = match fields.get("access_token") {
    None => None
    Some(String(value)) => Some(value)
    _ => raise @model.InvalidJson("Bearer access_token must be a string")
  }
  if token is Some(first) {
    if access_token is Some(second) {
      if first != second {
        raise @model.InvalidJson("conflicting Bearer token fields")
      }
    }
  }
  let value = match token {
    Some(value) => value
    None =>
      match access_token {
        Some(value) => value
        None => raise @model.InvalidJson("Bearer token response has no token")
      }
  }
  bearer_authorization(value)
}
