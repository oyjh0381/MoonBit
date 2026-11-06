///|
let max_json_bytes : Int32 = 16 * 1024 * 1024

///|
/// Validate an OCI Image Layout marker while tolerating extension fields and
/// insignificant JSON formatting differences.
pub fn validate_layout_marker(data : Bytes) -> Unit raise @model.MoonOciError {
  let root = parse_json_document(data)
  let object = expect_object(root, "OCI Image Layout marker")
  if required_string(object, "imageLayoutVersion") != "1.0.0" {
    raise @model.InvalidOci("imageLayoutVersion must be 1.0.0")
  }
}

///|
/// Decode an OCI Image Index. Unknown OCI fields are intentionally tolerated.
pub fn decode_index(
  data : Bytes,
) -> @model.ImageIndex raise @model.MoonOciError {
  let root = parse_json_document(data)
  let object = expect_object(root, "image index")
  {
    schema_version: required_int(object, "schemaVersion"),
    media_type: optional_string(object, "mediaType").unwrap_or(
      @model.media_type_index,
    ),
    manifests: descriptor_array(required(object, "manifests"), "manifests"),
    annotations: optional_string_map(object, "annotations"),
  }
}

///|
/// Decode an OCI Image Manifest. Unknown OCI fields are intentionally tolerated.
pub fn decode_manifest(
  data : Bytes,
) -> @model.ImageManifest raise @model.MoonOciError {
  let root = parse_json_document(data)
  let object = expect_object(root, "image manifest")
  {
    schema_version: required_int(object, "schemaVersion"),
    media_type: optional_string(object, "mediaType").unwrap_or(
      @model.media_type_manifest,
    ),
    config: decode_descriptor(required(object, "config")),
    layers: descriptor_array(required(object, "layers"), "layers"),
    annotations: optional_string_map(object, "annotations"),
  }
}

///|
/// Decode the Image Configuration fields used by MoonOCI verification.
pub fn decode_config(
  data : Bytes,
) -> @model.ImageConfig raise @model.MoonOciError {
  let root = parse_json_document(data)
  let object = expect_object(root, "image configuration")
  let platform : @model.Platform = {
    architecture: required_string(object, "architecture"),
    os: required_string(object, "os"),
    variant: optional_string(object, "variant"),
    os_version: optional_string(object, "os.version"),
  }
  let runtime = match object.get("config") {
    Some(value) => decode_runtime(value)
    None => @model.default_runtime_config()
  }
  let rootfs = expect_object(required(object, "rootfs"), "rootfs")
  if required_string(rootfs, "type") != "layers" {
    raise @model.InvalidOci("image configuration rootfs type must be layers")
  }
  let diff_ids = string_array(required(rootfs, "diff_ids"), "rootfs.diff_ids").map(value => {
      @model.Digest::parse(value)
    },
  )
  let history = match object.get("history") {
    Some(value) =>
      expect_array(value, "history").map(item => decode_history(item))
    None => []
  }
  {
    created: optional_string(object, "created"),
    author: optional_string(object, "author"),
    platform,
    runtime,
    diff_ids,
    history,
  }
}

///|
/// Decode one OCI Descriptor.
pub fn decode_descriptor(
  value : Json,
) -> @model.Descriptor raise @model.MoonOciError {
  let object = expect_object(value, "descriptor")
  {
    media_type: required_string(object, "mediaType"),
    digest: @model.Digest::parse(required_string(object, "digest")),
    size: required_int64(object, "size"),
    annotations: optional_string_map(object, "annotations"),
    platform: match object.get("platform") {
      Some(value) => Some(decode_platform(value))
      None => None
    },
  }
}

///|
/// Parse bounded UTF-8 JSON for portable consumers such as the Build
/// Specification parser. The returned tree has at most 128 nesting levels.
pub fn parse_json_document(data : Bytes) -> Json raise @model.MoonOciError {
  if data.length() > max_json_bytes {
    raise @model.ResourceLimitExceeded("JSON document exceeds 16 MiB")
  }
  let text = @utf8.decode(data) catch {
    _ => raise @model.InvalidJson("JSON document is not valid UTF-8")
  }
  reject_duplicate_object_keys(data)
  validate_json_depth(text, 128)
  @json.parse(text) catch {
    error => raise @model.InvalidJson("cannot parse JSON: " + error.to_string())
  }
}

///|
fn reject_duplicate_object_keys(data : Bytes) -> Unit raise @model.MoonOciError {
  let start = skip_json_space(data, 0)
  ignore(scan_json_value(data, start, 0))
}

///|
fn scan_json_value(
  data : Bytes,
  start : Int32,
  depth : Int32,
) -> Int32 raise @model.MoonOciError {
  if depth > 128 {
    raise @model.ResourceLimitExceeded("JSON nesting exceeds 128 levels")
  }
  let cursor = skip_json_space(data, start)
  if cursor >= data.length() {
    raise @model.InvalidJson("unexpected end of JSON")
  }
  match data[cursor] {
    b'{' => scan_json_object(data, cursor + 1, depth + 1)
    b'[' => scan_json_array(data, cursor + 1, depth + 1)
    b'"' => scan_json_string_end(data, cursor).1
    _ => {
      let mut end = cursor
      while end < data.length() &&
            data[end] != b',' &&
            data[end] != b']' &&
            data[end] != b'}' &&
            data[end] != b' ' &&
            data[end] != b'\t' &&
            data[end] != b'\r' &&
            data[end] != b'\n' {
        end += 1
      }
      if end == cursor {
        raise @model.InvalidJson("invalid JSON value")
      }
      end
    }
  }
}

///|
fn scan_json_object(
  data : Bytes,
  start : Int32,
  depth : Int32,
) -> Int32 raise @model.MoonOciError {
  let keys : Array[String] = []
  let mut cursor = skip_json_space(data, start)
  if cursor < data.length() && data[cursor] == b'}' {
    return cursor + 1
  }
  while cursor < data.length() {
    if data[cursor] != b'"' {
      raise @model.InvalidJson("JSON object key must be a string")
    }
    let (key, after_key) = scan_json_string_end(data, cursor)
    for existing in keys {
      if existing == key {
        raise @model.InvalidJson("duplicate JSON object key: " + key)
      }
    }
    keys.push(key)
    cursor = skip_json_space(data, after_key)
    if cursor >= data.length() || data[cursor] != b':' {
      raise @model.InvalidJson("JSON object key must be followed by colon")
    }
    cursor = scan_json_value(data, cursor + 1, depth)
    cursor = skip_json_space(data, cursor)
    if cursor < data.length() && data[cursor] == b',' {
      cursor = skip_json_space(data, cursor + 1)
      continue
    }
    if cursor < data.length() && data[cursor] == b'}' {
      return cursor + 1
    }
    raise @model.InvalidJson("JSON object is not terminated")
  }
  raise @model.InvalidJson("unexpected end of JSON object")
}

///|
fn scan_json_array(
  data : Bytes,
  start : Int32,
  depth : Int32,
) -> Int32 raise @model.MoonOciError {
  let mut cursor = skip_json_space(data, start)
  if cursor < data.length() && data[cursor] == b']' {
    return cursor + 1
  }
  while cursor < data.length() {
    cursor = scan_json_value(data, cursor, depth)
    cursor = skip_json_space(data, cursor)
    if cursor < data.length() && data[cursor] == b',' {
      cursor = skip_json_space(data, cursor + 1)
      continue
    }
    if cursor < data.length() && data[cursor] == b']' {
      return cursor + 1
    }
    raise @model.InvalidJson("JSON array is not terminated")
  }
  raise @model.InvalidJson("unexpected end of JSON array")
}

///|
fn scan_json_string_end(
  data : Bytes,
  start : Int32,
) -> (String, Int32) raise @model.MoonOciError {
  let mut cursor = start + 1
  let mut escaped = false
  while cursor < data.length() {
    let byte = data[cursor]
    if escaped {
      escaped = false
    } else if byte == b'\\' {
      escaped = true
    } else if byte == b'"' {
      let end = cursor + 1
      let token = @utf8.decode(data[start:end]) catch {
        _ => raise @model.InvalidJson("JSON string is not valid UTF-8")
      }
      let decoded = @json.parse(token) catch {
        _ => raise @model.InvalidJson("invalid JSON string escape")
      }
      return match decoded {
        String(value) => (value, end)
        _ => raise @model.InvalidJson("invalid JSON string")
      }
    }
    cursor += 1
  }
  raise @model.InvalidJson("unterminated JSON string")
}

///|
fn skip_json_space(data : Bytes, start : Int32) -> Int32 {
  let mut cursor = start
  while cursor < data.length() &&
        (
          data[cursor] == b' ' ||
          data[cursor] == b'\t' ||
          data[cursor] == b'\r' ||
          data[cursor] == b'\n'
        ) {
    cursor += 1
  }
  cursor
}

///|
fn validate_json_depth(
  text : String,
  maximum : Int32,
) -> Unit raise @model.MoonOciError {
  let mut depth = 0
  let mut in_string = false
  let mut escaped = false
  for char in text {
    if in_string {
      if escaped {
        escaped = false
      } else if char == '\\' {
        escaped = true
      } else if char == '"' {
        in_string = false
      }
    } else if char == '"' {
      in_string = true
    } else if char == '{' || char == '[' {
      depth += 1
      if depth > maximum {
        raise @model.ResourceLimitExceeded("JSON nesting exceeds 128 levels")
      }
    } else if char == '}' || char == ']' {
      depth -= 1
      if depth < 0 {
        raise @model.InvalidJson("JSON nesting is unbalanced")
      }
    }
  }
}

///|
fn expect_object(
  value : Json,
  context : String,
) -> Map[String, Json] raise @model.MoonOciError {
  match value {
    Object(object) => object
    _ => raise @model.InvalidJson(context + " must be a JSON object")
  }
}

///|
fn expect_array(
  value : Json,
  context : String,
) -> Array[Json] raise @model.MoonOciError {
  match value {
    Array(items) => items
    _ => raise @model.InvalidJson(context + " must be a JSON array")
  }
}

///|
fn required(
  object : Map[String, Json],
  name : String,
) -> Json raise @model.MoonOciError {
  match object.get(name) {
    Some(value) => value
    None => raise @model.InvalidJson("missing required JSON field: " + name)
  }
}

///|
fn required_string(
  object : Map[String, Json],
  name : String,
) -> String raise @model.MoonOciError {
  expect_string(required(object, name), name)
}

///|
fn optional_string(
  object : Map[String, Json],
  name : String,
) -> String? raise @model.MoonOciError {
  match object.get(name) {
    Some(Null) | None => None
    Some(value) => Some(expect_string(value, name))
  }
}

///|
fn expect_string(
  value : Json,
  context : String,
) -> String raise @model.MoonOciError {
  match value {
    String(text) => text
    _ => raise @model.InvalidJson(context + " must be a JSON string")
  }
}

///|
fn required_int(
  object : Map[String, Json],
  name : String,
) -> Int32 raise @model.MoonOciError {
  let value : Int32 = @json.from_json(required(object, name)) catch {
    _ => raise @model.InvalidJson(name + " must be an integer")
  }
  value
}

///|
fn required_int64(
  object : Map[String, Json],
  name : String,
) -> Int64 raise @model.MoonOciError {
  let value = match required(object, name) {
    Number(number, repr~) =>
      match repr {
        Some(text) =>
          @string.parse_int64(text) catch {
            _ => raise @model.InvalidJson(name + " must be a 64-bit integer")
          }
        None => {
          if number != number.floor() ||
            number < 0.0 ||
            number > 9007199254740991.0 {
            raise @model.InvalidJson(
              name + " must be an exact non-negative integer",
            )
          }
          number.to_int64()
        }
      }
    _ => raise @model.InvalidJson(name + " must be a 64-bit integer")
  }
  if value < 0L {
    raise @model.InvalidOci(name + " must not be negative")
  }
  value
}

///|
fn descriptor_array(
  value : Json,
  context : String,
) -> Array[@model.Descriptor] raise @model.MoonOciError {
  expect_array(value, context).map(item => decode_descriptor(item))
}

///|
fn string_array(
  value : Json,
  context : String,
) -> Array[String] raise @model.MoonOciError {
  expect_array(value, context).map(item => expect_string(item, context))
}

///|
fn optional_string_array(
  object : Map[String, Json],
  name : String,
) -> Array[String] raise @model.MoonOciError {
  match object.get(name) {
    Some(value) => string_array(value, name)
    None => []
  }
}

///|
fn optional_string_map(
  object : Map[String, Json],
  name : String,
) -> Array[@model.KeyValue] raise @model.MoonOciError {
  match object.get(name) {
    None => []
    Some(value) => {
      let map = expect_object(value, name)
      let result : Array[@model.KeyValue] = []
      for key in map.keys() {
        result.push({
          key,
          value: expect_string(required(map, key), name + "." + key),
        })
      }
      result.sort_by((a, b) => @pathing.compare_utf8(a.key, b.key))
      result
    }
  }
}

///|
fn decode_platform(value : Json) -> @model.Platform raise @model.MoonOciError {
  let object = expect_object(value, "platform")
  {
    architecture: required_string(object, "architecture"),
    os: required_string(object, "os"),
    variant: optional_string(object, "variant"),
    os_version: optional_string(object, "os.version"),
  }
}

///|
fn decode_runtime(
  value : Json,
) -> @model.RuntimeConfig raise @model.MoonOciError {
  let object = expect_object(value, "config")
  let env : Array[@model.KeyValue] = []
  for item in optional_string_array(object, "Env") {
    match item.split_once("=") {
      Some((key, value)) =>
        env.push({ key: key.to_owned(), value: value.to_owned(), })
      None => env.push({ key: item, value: "", })
    }
  }
  {
    user: optional_string(object, "User"),
    env,
    entrypoint: optional_string_array(object, "Entrypoint"),
    cmd: optional_string_array(object, "Cmd"),
    working_dir: optional_string(object, "WorkingDir").unwrap_or("/"),
    labels: optional_string_map(object, "Labels"),
    exposed_ports: optional_object_keys(object, "ExposedPorts"),
    volumes: optional_object_keys(object, "Volumes"),
    stop_signal: optional_string(object, "StopSignal"),
  }
}

///|
fn optional_object_keys(
  object : Map[String, Json],
  name : String,
) -> Array[String] raise @model.MoonOciError {
  match object.get(name) {
    None => []
    Some(value) => {
      let keys = expect_object(value, name).keys().collect()
      keys.sort_by((a, b) => @pathing.compare_utf8(a, b))
      keys
    }
  }
}

///|
fn decode_history(value : Json) -> @model.History raise @model.MoonOciError {
  let object = expect_object(value, "history item")
  {
    created: optional_string(object, "created"),
    created_by: optional_string(object, "created_by"),
    author: optional_string(object, "author"),
    comment: optional_string(object, "comment"),
    empty_layer: match object.get("empty_layer") {
      Some(True) => true
      Some(False) | None => false
      _ => raise @model.InvalidJson("history.empty_layer must be boolean")
    },
  }
}
