///|
/// Parse and strictly validate a schemaVersion 1 Build Specification.
pub fn parse_build_spec(data : Bytes) -> BuildSpec raise @model.MoonOciError {
  let root = @codec.parse_json_document(data)
  let object = expect_object(root, "build specification")
  reject_unknown(
    object,
    [
      "schemaVersion", "ref", "platform", "layers", "config", "created", "author",
      "annotations", "output",
    ],
    "build specification",
  )
  let schema_version = required_int(object, "schemaVersion")
  if schema_version != 1 {
    raise @model.InvalidBuildSpec("schemaVersion must be exactly 1")
  }
  let reference = optional_string(object, "ref").unwrap_or("latest")
  if reference == "" || reference.contains_char('\u{0000}') {
    raise @model.InvalidBuildSpec("ref must be a non-empty string without NUL")
  }
  let platform = match object.get("platform") {
    Some(value) => parse_platform(value)
    None => @model.default_platform()
  }
  let layers = required_array(object, "layers").map(value => parse_layer(value))
  if layers.length() == 0 {
    raise @model.InvalidBuildSpec("layers must contain at least one layer")
  }
  let runtime = match object.get("config") {
    Some(value) => parse_runtime(value)
    None => @model.default_runtime_config()
  }
  let output = match object.get("output") {
    Some(value) => parse_output(value)
    None => { layout: "oci-layout", }
  }
  {
    schema_version,
    reference,
    platform,
    layers,
    runtime,
    created: optional_string(object, "created"),
    author: optional_string(object, "author"),
    annotations: optional_string_map(object, "annotations"),
    output,
  }
}

///|
fn parse_platform(value : Json) -> @model.Platform raise @model.MoonOciError {
  let object = expect_object(value, "platform")
  reject_unknown(
    object,
    ["os", "architecture", "variant", "osVersion"],
    "platform",
  )
  let os = optional_string(object, "os").unwrap_or("linux")
  let architecture = optional_string(object, "architecture").unwrap_or("amd64")
  if os == "" || architecture == "" {
    raise @model.InvalidBuildSpec(
      "platform os and architecture must not be empty",
    )
  }
  {
    os,
    architecture,
    variant: optional_string(object, "variant"),
    os_version: optional_string(object, "osVersion"),
  }
}

///|
fn parse_layer(value : Json) -> LayerSpec raise @model.MoonOciError {
  let object = expect_object(value, "layer")
  reject_unknown(
    object,
    [
      "source", "compression", "remove", "opaque", "exclude", "ignoreFile", "metadata",
    ],
    "layer",
  )
  let source = required_string(object, "source")
  if source == "" || source.contains_char('\u{0000}') {
    raise @model.InvalidBuildSpec(
      "layer source must not be empty or contain NUL",
    )
  }
  let compression = match optional_string(object, "compression") {
    None => @model.Compression::Uncompressed
    Some("none") => @model.Compression::Uncompressed
    Some("gzip") => @model.Compression::Gzip
    Some(value) =>
      raise @model.InvalidBuildSpec("unsupported layer compression: " + value)
  }
  let remove = optional_string_array(object, "remove").map(path => {
    @pathing.normalize_spec_path(path)
  })
  let opaque_dirs = optional_string_array(object, "opaque").map(path => {
    if path == "/" {
      "/"
    } else {
      @pathing.normalize_spec_path(path)
    }
  })
  let exclude = optional_string_array(object, "exclude")
  for pattern in exclude {
    if pattern == "" ||
      pattern.contains_char('\u{0000}') ||
      pattern.contains("\\") {
      raise @model.InvalidBuildSpec(
        "exclude patterns must be non-empty forward-slash paths",
      )
    }
  }
  {
    source,
    compression,
    remove,
    opaque_dirs,
    exclude,
    ignore_file: optional_string(object, "ignoreFile"),
    metadata: match object.get("metadata") {
      Some(value) => parse_metadata(value)
      None => default_metadata_spec()
    },
  }
}

///|
fn parse_metadata(value : Json) -> MetadataSpec raise @model.MoonOciError {
  let object = expect_object(value, "layer metadata")
  reject_unknown(
    object,
    ["mode", "uid", "gid", "mtime", "preserveMtime"],
    "layer metadata",
  )
  let mode = optional_int(object, "mode")
  match mode {
    Some(value) if value < 0 || value > 0o7777 =>
      raise @model.InvalidBuildSpec("metadata mode must be between 0 and 07777")
    _ => ()
  }
  let uid = optional_int(object, "uid")
  let gid = optional_int(object, "gid")
  if uid.unwrap_or(0) < 0 || gid.unwrap_or(0) < 0 {
    raise @model.InvalidBuildSpec("metadata uid and gid must not be negative")
  }
  {
    mode,
    uid,
    gid,
    mtime: optional_int64(object, "mtime"),
    preserve_mtime: optional_bool(object, "preserveMtime").unwrap_or(false),
  }
}

///|
fn parse_runtime(
  value : Json,
) -> @model.RuntimeConfig raise @model.MoonOciError {
  let object = expect_object(value, "config")
  reject_unknown(
    object,
    [
      "user", "env", "entrypoint", "cmd", "workingDir", "labels", "exposedPorts",
      "volumes", "stopSignal",
    ],
    "config",
  )
  let working_dir = optional_string(object, "workingDir").unwrap_or("/")
  if !working_dir.has_prefix("/") {
    raise @model.InvalidBuildSpec(
      "config.workingDir must be an absolute container path",
    )
  }
  {
    user: optional_string(object, "user"),
    env: optional_string_map(object, "env"),
    entrypoint: optional_string_array(object, "entrypoint"),
    cmd: optional_string_array(object, "cmd"),
    working_dir,
    labels: optional_string_map(object, "labels"),
    exposed_ports: optional_string_array(object, "exposedPorts"),
    volumes: optional_string_array(object, "volumes"),
    stop_signal: optional_string(object, "stopSignal"),
  }
}

///|
fn parse_output(value : Json) -> OutputSpec raise @model.MoonOciError {
  let object = expect_object(value, "output")
  reject_unknown(object, ["layout"], "output")
  let layout = optional_string(object, "layout").unwrap_or("oci-layout")
  if layout == "" || layout.contains_char('\u{0000}') {
    raise @model.InvalidBuildSpec(
      "output.layout must not be empty or contain NUL",
    )
  }
  { layout, }
}

///|
fn reject_unknown(
  object : Map[String, Json],
  allowed : Array[String],
  context : String,
) -> Unit raise @model.MoonOciError {
  for key in object.keys() {
    let mut known = false
    for candidate in allowed {
      if key == candidate {
        known = true
        break
      }
    }
    if !known {
      raise @model.InvalidBuildSpec("unknown " + context + " field: " + key)
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
    _ => raise @model.InvalidBuildSpec(context + " must be an object")
  }
}

///|
fn required(
  object : Map[String, Json],
  name : String,
) -> Json raise @model.MoonOciError {
  match object.get(name) {
    Some(value) => value
    None => raise @model.InvalidBuildSpec("missing required field: " + name)
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
    _ => raise @model.InvalidBuildSpec(context + " must be a string")
  }
}

///|
fn required_array(
  object : Map[String, Json],
  name : String,
) -> Array[Json] raise @model.MoonOciError {
  match required(object, name) {
    Array(items) => items
    _ => raise @model.InvalidBuildSpec(name + " must be an array")
  }
}

///|
fn optional_string_array(
  object : Map[String, Json],
  name : String,
) -> Array[String] raise @model.MoonOciError {
  match object.get(name) {
    None => []
    Some(Array(items)) => items.map(item => expect_string(item, name))
    _ => raise @model.InvalidBuildSpec(name + " must be an array of strings")
  }
}

///|
fn required_int(
  object : Map[String, Json],
  name : String,
) -> Int32 raise @model.MoonOciError {
  match required(object, name) {
    Number(number, ..) if number == number.floor() &&
      number >= -2147483648.0 &&
      number <= 2147483647.0 => number.to_int()
    _ => raise @model.InvalidBuildSpec(name + " must be an integer")
  }
}

///|
fn optional_int(
  object : Map[String, Json],
  name : String,
) -> Int32? raise @model.MoonOciError {
  match object.get(name) {
    None => None
    Some(_) => Some(required_int(object, name))
  }
}

///|
fn optional_int64(
  object : Map[String, Json],
  name : String,
) -> Int64? raise @model.MoonOciError {
  match object.get(name) {
    None => None
    Some(Number(number, repr~)) => {
      let value = match repr {
        Some(text) =>
          @string.parse_int64(text) catch {
            _ =>
              raise @model.InvalidBuildSpec(name + " must be a 64-bit integer")
          }
        None => {
          if number != number.floor() ||
            number < 0.0 ||
            number > 9007199254740991.0 {
            raise @model.InvalidBuildSpec(
              name + " must be an exact non-negative integer",
            )
          }
          number.to_int64()
        }
      }
      Some(value)
    }
    _ => raise @model.InvalidBuildSpec(name + " must be a 64-bit integer")
  }
}

///|
fn optional_bool(
  object : Map[String, Json],
  name : String,
) -> Bool? raise @model.MoonOciError {
  match object.get(name) {
    None => None
    Some(True) => Some(true)
    Some(False) => Some(false)
    _ => raise @model.InvalidBuildSpec(name + " must be boolean")
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
