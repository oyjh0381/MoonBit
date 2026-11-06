///|
/// ASCII HTTP origin; no userinfo, path, query or fragment. HTTPS is required
/// unless the caller explicitly opts into plaintext transport.
pub struct RegistryOrigin {
  priv scheme : String
  priv authority : String
}

///|
pub struct RegistryUrl {
  priv origin : RegistryOrigin
  priv path : String
}

///|
fn hex_digit(ch : Char) -> Bool {
  (ch >= '0' && ch <= '9') ||
  (ch >= 'a' && ch <= 'f') ||
  (ch >= 'A' && ch <= 'F')
}

///|
fn ipv4(value : String) -> Bool {
  let parts = value.split(".").collect()
  if parts.length() != 4 {
    return false
  }
  for part in parts {
    if part.is_empty() ||
      part.length() > 3 ||
      (part.length() > 1 && part.has_prefix("0")) {
      return false
    }
    let mut number = 0
    for ch in part {
      if ch < '0' || ch > '9' {
        return false
      }
      number = number * 10 + ch.to_int() - '0'.to_int()
    }
    if number > 255 {
      return false
    }
  }
  true
}

///|
fn ipv6(value : String) -> Bool {
  let halves = value.split("::").collect()
  if halves.length() > 2 {
    return false
  }
  let mut units = 0
  for half_index, half in halves {
    if half.is_empty() {
      if halves.length() == 1 {
        return false
      }
      continue
    }
    let parts = half.split(":").collect()
    for index, part in parts {
      if part.contains(".") {
        if half_index != halves.length() - 1 ||
          index != parts.length() - 1 ||
          !ipv4(part.to_owned()) {
          return false
        }
        units += 2
      } else {
        if part.is_empty() || part.length() > 4 {
          return false
        }
        for ch in part {
          if !hex_digit(ch) {
            return false
          }
        }
        units += 1
      }
    }
  }
  if halves.length() == 2 {
    units < 8
  } else {
    units == 8
  }
}

///|
fn dns_host(value : String) -> Bool {
  if value.is_empty() || value.length() > 253 {
    return false
  }
  let numeric = value
    .to_array()
    .all(ch => (ch >= '0' && ch <= '9') || ch == '.')
  if numeric {
    return ipv4(value)
  }
  let labels = value.split(".").collect()
  for index, label in labels {
    if label.is_empty() && index == labels.length() - 1 && index > 0 {
      continue
    }
    if label.is_empty() ||
      label.length() > 63 ||
      label.has_prefix("-") ||
      label.has_suffix("-") {
      return false
    }
    for ch in label {
      if !name_character(ch) && ch != '-' {
        return false
      }
    }
  }
  true
}

///|
pub fn RegistryOrigin::parse(
  value : String,
  allow_http~ : Bool = false,
) -> RegistryOrigin raise @model.MoonOciError {
  if value.length() > 2048 {
    raise @model.ResourceLimitExceeded("registry origin exceeds length quota")
  }
  let value = if value.has_suffix("/") {
    value[0:value.length() - 1].to_owned()
  } else {
    value
  }
  let parts = value.split("://").collect()
  if parts.length() != 2 {
    raise @model.InvalidArgument(
      "registry origin requires an explicit http(s) scheme",
    )
  }
  let scheme = parts[0].to_owned().to_lower()
  if scheme != "https" && scheme != "http" {
    raise @model.Unsupported("registry origin scheme must be http or https")
  }
  if scheme == "http" && !allow_http {
    raise @model.InvalidArgument(
      "plaintext registry HTTP requires explicit opt-in",
    )
  }
  for ch in parts[1] {
    if ch <= ' ' || ch >= '\u{007f}' {
      raise @model.InvalidArgument("registry authority must be visible ASCII")
    }
  }
  let authority = parts[1].to_owned().to_lower()
  if authority.is_empty() {
    raise @model.InvalidArgument("registry origin has no authority")
  }
  let (host, port) = if authority.has_prefix("[") {
    let end = match authority.find("]") {
      Some(end) => end
      None => raise @model.InvalidArgument("unterminated IPv6 authority")
    }
    let address = authority[1:end].to_owned()
    if !ipv6(address) {
      raise @model.InvalidArgument("invalid IPv6 registry literal")
    }
    let tail = authority[end + 1:].to_owned()
    let port = if tail.is_empty() {
      ""
    } else if tail.has_prefix(":") {
      tail[1:].to_owned()
    } else {
      raise @model.InvalidArgument("invalid IPv6 authority suffix")
    }
    if !tail.is_empty() && port.is_empty() {
      raise @model.InvalidArgument("empty registry port")
    }
    ("[" + address + "]", port)
  } else {
    let fields = authority.split(":").collect()
    if fields.length() > 2 {
      raise @model.InvalidArgument("IPv6 registry literals require brackets")
    }
    let host = fields[0].to_owned()
    if !dns_host(host) {
      raise @model.InvalidArgument("invalid ASCII registry hostname")
    }
    let port = if fields.length() == 2 { fields[1].to_owned() } else { "" }
    if fields.length() == 2 && port.is_empty() {
      raise @model.InvalidArgument("empty registry port")
    }
    (host, port)
  }
  let port = if port.is_empty() {
    if scheme == "https" {
      443
    } else {
      80
    }
  } else {
    for ch in port {
      if ch < '0' || ch > '9' {
        raise @model.InvalidArgument("registry port must be decimal")
      }
    }
    @string.parse_int(port) catch {
      _ =>
        raise @model.InvalidArgument(
          "registry port is outside the integer range",
        )
    }
  }
  if port < 1 || port > 65535 {
    raise @model.InvalidArgument("registry port must be in 1..65535")
  }
  let default_port = if scheme == "https" { 443 } else { 80 }
  let authority = host +
    (if port == default_port { "" } else { ":" + port.to_string() })
  { scheme, authority, }
}

///|
pub fn RegistryOrigin::url(self : RegistryOrigin) -> String {
  self.scheme + "://" + self.authority
}

///|
pub fn RegistryOrigin::is_http(self : RegistryOrigin) -> Bool {
  self.scheme == "http"
}

///|
pub fn RegistryOrigin::same_origin(
  self : RegistryOrigin,
  other : RegistryOrigin,
) -> Bool {
  self.scheme == other.scheme && self.authority == other.authority
}

///|
fn validate_url_path(path : String) -> Unit raise @model.MoonOciError {
  if !path.has_prefix("/") || path.has_prefix("//") || path.length() > 8192 {
    raise @model.InvalidArgument(
      "registry URL requires a bounded absolute path",
    )
  }
  let chars = path.to_array()
  let mut index = 0
  while index < chars.length() {
    let ch = chars[index]
    if ch <= ' ' || ch >= '\u{007f}' || ch == '#' || ch == '\\' {
      raise @model.InvalidArgument(
        "registry URL path must be escaped ASCII without a fragment",
      )
    }
    if ch == '%' {
      if index + 2 >= chars.length() ||
        !hex_digit(chars[index + 1]) ||
        !hex_digit(chars[index + 2]) {
        raise @model.InvalidArgument("invalid percent escape in registry URL")
      }
      index += 2
    }
    index += 1
  }
}

///|
pub fn RegistryUrl::parse(
  value : String,
  allow_http~ : Bool = false,
) -> RegistryUrl raise @model.MoonOciError {
  if value.length() > 8192 {
    raise @model.ResourceLimitExceeded("registry URL exceeds length quota")
  }
  let delimiter = match value.find("://") {
    Some(value) => value
    None =>
      raise @model.InvalidArgument("registry URL requires an absolute scheme")
  }
  let remainder = value[delimiter + 3:]
  let mut boundary = remainder.length()
  if remainder.find("/") is Some(index) {
    if index < boundary {
      boundary = index
    }
  }
  if remainder.find("?") is Some(index) {
    if index < boundary {
      boundary = index
    }
  }
  let origin = RegistryOrigin::parse(
    value[0:delimiter + 3 + boundary].to_owned(),
    allow_http~,
  )
  let tail = remainder[boundary:].to_owned()
  let path = if tail.is_empty() {
    "/"
  } else if tail.has_prefix("?") {
    "/" + tail
  } else {
    tail
  }
  validate_url_path(path)
  { origin, path, }
}

///|
pub fn RegistryOrigin::request_url(
  self : RegistryOrigin,
  path : String,
) -> RegistryUrl raise @model.MoonOciError {
  validate_url_path(path)
  { origin: self, path, }
}

///|
pub fn RegistryUrl::origin(self : RegistryUrl) -> RegistryOrigin {
  self.origin
}

///|
pub fn RegistryUrl::path(self : RegistryUrl) -> String {
  self.path
}

///|
pub fn RegistryUrl::url(self : RegistryUrl) -> String {
  self.origin.url() + self.path
}

///|
/// Resolve absolute/root-relative locations. Network-path and relative-path
/// references are refused; callers do not silently inherit a new authority.
pub fn RegistryOrigin::resolve(
  self : RegistryOrigin,
  location : String,
  allow_http~ : Bool = false,
) -> RegistryUrl raise @model.MoonOciError {
  if location.has_prefix("/") {
    self.request_url(location)
  } else {
    RegistryUrl::parse(location, allow_http~)
  }
}
