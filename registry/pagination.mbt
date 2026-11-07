///|
// Parse Link values without splitting quoted commas or URI queries. This
// profile refuses contextual anchors and duplicate attributes on next links.
fn next_link(input : String) -> String? raise @model.MoonOciError {
  let chars = input.to_array()
  let mut cursor = skip_ows(chars, 0)
  let mut result = None
  while cursor < chars.length() {
    if chars[cursor] != '<' {
      raise @model.InvalidOci("pagination Link requires angle-bracket target")
    }
    cursor += 1
    let start = cursor
    while cursor < chars.length() && chars[cursor] != '>' {
      cursor += 1
    }
    if cursor == chars.length() || cursor == start {
      raise @model.InvalidOci("invalid pagination Link target")
    }
    let target = String::from_array(chars[start:cursor].to_owned())
    cursor = skip_ows(chars, cursor + 1)
    let fields : Map[String, String] = Map([])
    while cursor < chars.length() && chars[cursor] == ';' {
      cursor = skip_ows(chars, cursor + 1)
      let start = cursor
      while cursor < chars.length() && header_token(chars[cursor]) {
        cursor += 1
      }
      let key = String::from_array(chars[start:cursor].to_owned()).to_lower()
      if key.is_empty() || fields.contains(key) {
        raise @model.InvalidOci(
          "invalid or duplicate pagination Link parameter",
        )
      }
      cursor = skip_ows(chars, cursor)
      if cursor == chars.length() || chars[cursor] != '=' {
        raise @model.InvalidOci("pagination Link parameter requires equals")
      }
      cursor = skip_ows(chars, cursor + 1)
      let output = StringBuilder()
      if cursor < chars.length() && chars[cursor] == '"' {
        cursor += 1
        let mut closed = false
        while cursor < chars.length() {
          let ch = chars[cursor]
          cursor += 1
          if ch == '"' {
            closed = true
            break
          }
          if ch == '\\' {
            if cursor == chars.length() {
              raise @model.InvalidOci("incomplete pagination Link escape")
            }
            output.write_char(chars[cursor])
            cursor += 1
          } else {
            output.write_char(ch)
          }
        }
        if !closed {
          raise @model.InvalidOci("unterminated pagination Link parameter")
        }
      } else {
        let start = cursor
        while cursor < chars.length() && header_token(chars[cursor]) {
          output.write_char(chars[cursor])
          cursor += 1
        }
        if start == cursor {
          raise @model.InvalidOci("empty pagination Link parameter")
        }
      }
      fields[key] = output.to_string()
      cursor = skip_ows(chars, cursor)
    }
    if fields.get("rel").unwrap_or("").split(" ").any(rel => rel == "next") {
      if result is Some(_) || fields.contains("anchor") {
        raise @model.InvalidOci("ambiguous or contextual pagination next link")
      }
      result = Some(target)
    }
    if cursor < chars.length() {
      if chars[cursor] != ',' {
        raise @model.InvalidOci("invalid pagination Link delimiter")
      }
      cursor = skip_ows(chars, cursor + 1)
      if cursor == chars.length() {
        raise @model.InvalidOci("trailing pagination Link delimiter")
      }
    }
  }
  result
}

///|
/// Restrict pagination to the same origin and exact endpoint. A next link may
/// carry opaque last/n parameters, but cannot broaden/narrow the type filter.
/// Root-relative and absolute links are supported; relative links are refused.
pub fn referrer_next_path(
  origin : RegistryOrigin,
  repository : String,
  subject : @model.Digest,
  headers : Array[@model.KeyValue],
  artifact_type? : String,
) -> String? raise @model.MoonOciError {
  let initial = referrers_path(repository, subject, artifact_type?)
  let target = match single_header(headers, "link") {
    None => return None
    Some(value) =>
      match next_link(value) {
        None => return None
        Some(value) => value
      }
  }
  let url = origin.resolve(target, allow_http=origin.is_http())
  if !url.origin().same_origin(origin) {
    raise @model.InvalidOci("referrer pagination cannot change origin")
  }
  let parts = url.path().split("?").collect()
  if parts.length() > 2 || parts[0] != initial.split("?").collect()[0] {
    raise @model.InvalidOci("referrer pagination cannot change endpoint")
  }
  let parameters : Map[String, String] = Map([])
  if parts.length() == 2 {
    for pair in parts[1].split("&") {
      let fields = pair.split("=").collect()
      if fields.length() != 2 || fields[1].is_empty() {
        raise @model.InvalidOci("invalid referrer pagination query")
      }
      let key = fields[0].to_owned()
      let value = fields[1].to_owned()
      if !["last", "n", "artifactType"].contains(key) ||
        parameters.contains(key) {
        raise @model.InvalidOci("unexpected or duplicate pagination parameter")
      }
      if key == "n" {
        let count = @string.parse_int(value) catch {
          _ => raise @model.InvalidOci("invalid pagination page size")
        }
        if count < 1 ||
          count > 1000 ||
          !value.to_array().all(ch => ch >= '0' && ch <= '9') {
          raise @model.InvalidOci("pagination page size must be in 1..1000")
        }
      }
      parameters[key] = value
    }
  }
  if parameters.get("artifactType") is Some(value) {
    if artifact_type.map(encode_query_value) != Some(value) {
      raise @model.InvalidOci(
        "referrer pagination changed artifact type filter",
      )
    }
  } else if artifact_type is Some(value) {
    return Some(
      url.path() +
      (if parts.length() == 2 { "&" } else { "?" }) +
      "artifactType=" +
      encode_query_value(value),
    )
  }
  Some(url.path())
}
