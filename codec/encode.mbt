///|
/// Encode an OCI descriptor with a fixed field order.
pub fn encode_descriptor(
  descriptor : @model.Descriptor,
) -> String raise @model.MoonOciError {
  let fields = [
    field("mediaType", quote(descriptor.media_type)),
    field("digest", quote(descriptor.digest.to_string())),
    field("size", descriptor.size.to_string()),
  ]
  if descriptor.annotations.length() > 0 {
    fields.push(field("annotations", encode_string_map(descriptor.annotations)))
  }
  match descriptor.platform {
    Some(platform) => fields.push(field("platform", encode_platform(platform)))
    None => ()
  }
  object(fields)
}

///|
/// Encode an OCI image manifest as deterministic UTF-8 JSON bytes.
pub fn encode_manifest(
  manifest : @model.ImageManifest,
) -> Bytes raise @model.MoonOciError {
  let fields = [
    field("schemaVersion", manifest.schema_version.to_string()),
    field("mediaType", quote(manifest.media_type)),
    field("config", encode_descriptor(manifest.config)),
    field(
      "layers",
      array(manifest.layers.map(layer => encode_descriptor(layer))),
    ),
  ]
  if manifest.annotations.length() > 0 {
    fields.push(field("annotations", encode_string_map(manifest.annotations)))
  }
  @utf8.encode(object(fields))
}

///|
/// Encode an OCI image index as deterministic UTF-8 JSON bytes.
pub fn encode_index(
  index : @model.ImageIndex,
) -> Bytes raise @model.MoonOciError {
  let fields = [
    field("schemaVersion", index.schema_version.to_string()),
    field("mediaType", quote(index.media_type)),
    field(
      "manifests",
      array(index.manifests.map(item => encode_descriptor(item))),
    ),
  ]
  if index.annotations.length() > 0 {
    fields.push(field("annotations", encode_string_map(index.annotations)))
  }
  @utf8.encode(object(fields))
}

///|
/// Encode an OCI image configuration as deterministic UTF-8 JSON bytes.
pub fn encode_config(
  config : @model.ImageConfig,
) -> Bytes raise @model.MoonOciError {
  let fields : Array[String] = []
  add_optional_string(fields, "created", config.created)
  add_optional_string(fields, "author", config.author)
  fields.push(field("architecture", quote(config.platform.architecture)))
  fields.push(field("os", quote(config.platform.os)))
  match config.platform.os_version {
    Some(value) => fields.push(field("os.version", quote(value)))
    None => ()
  }
  match config.platform.variant {
    Some(value) => fields.push(field("variant", quote(value)))
    None => ()
  }
  fields.push(field("config", encode_runtime(config.runtime)))
  fields.push(field("rootfs", encode_rootfs(config.diff_ids)))
  if config.history.length() > 0 {
    fields.push(
      field("history", array(config.history.map(item => encode_history(item)))),
    )
  }
  @utf8.encode(object(fields))
}

///|
fn encode_platform(platform : @model.Platform) -> String {
  let fields = [
    field("architecture", quote(platform.architecture)),
    field("os", quote(platform.os)),
  ]
  match platform.os_version {
    Some(value) => fields.push(field("os.version", quote(value)))
    None => ()
  }
  match platform.variant {
    Some(value) => fields.push(field("variant", quote(value)))
    None => ()
  }
  object(fields)
}

///|
fn encode_runtime(
  runtime : @model.RuntimeConfig,
) -> String raise @model.MoonOciError {
  let fields : Array[String] = []
  add_optional_string(fields, "User", runtime.user)
  if runtime.exposed_ports.length() > 0 {
    fields.push(
      field("ExposedPorts", encode_empty_object_set(runtime.exposed_ports)),
    )
  }
  let env = sorted_pairs(runtime.env).map(item => item.key + "=" + item.value)
  if env.length() > 0 {
    fields.push(field("Env", encode_string_array(env)))
  }
  if runtime.entrypoint.length() > 0 {
    fields.push(field("Entrypoint", encode_string_array(runtime.entrypoint)))
  }
  if runtime.cmd.length() > 0 {
    fields.push(field("Cmd", encode_string_array(runtime.cmd)))
  }
  if runtime.volumes.length() > 0 {
    fields.push(field("Volumes", encode_empty_object_set(runtime.volumes)))
  }
  if runtime.working_dir != "" {
    fields.push(field("WorkingDir", quote(runtime.working_dir)))
  }
  if runtime.labels.length() > 0 {
    fields.push(field("Labels", encode_string_map(runtime.labels)))
  }
  add_optional_string(fields, "StopSignal", runtime.stop_signal)
  object(fields)
}

///|
fn encode_rootfs(diff_ids : Array[@model.Digest]) -> String {
  object([
    field("type", quote("layers")),
    field(
      "diff_ids",
      encode_string_array(diff_ids.map(digest => digest.to_string())),
    ),
  ])
}

///|
fn encode_history(history : @model.History) -> String {
  let fields : Array[String] = []
  add_optional_string(fields, "created", history.created)
  add_optional_string(fields, "created_by", history.created_by)
  add_optional_string(fields, "author", history.author)
  add_optional_string(fields, "comment", history.comment)
  if history.empty_layer {
    fields.push(field("empty_layer", "true"))
  }
  object(fields)
}

///|
fn encode_string_map(
  values : Array[@model.KeyValue],
) -> String raise @model.MoonOciError {
  let sorted = sorted_pairs(values)
  let fields : Array[String] = []
  for i, item in sorted {
    if i > 0 && sorted[i - 1].key == item.key {
      raise @model.InvalidArgument("duplicate map key: " + item.key)
    }
    fields.push(field(item.key, quote(item.value)))
  }
  object(fields)
}

///|
fn encode_empty_object_set(
  values : Array[String],
) -> String raise @model.MoonOciError {
  let sorted = values.copy()
  sorted.sort_by((a, b) => @pathing.compare_utf8(a, b))
  let fields : Array[String] = []
  for i, value in sorted {
    if i > 0 && sorted[i - 1] == value {
      raise @model.InvalidArgument("duplicate set member: " + value)
    }
    fields.push(field(value, "{}"))
  }
  object(fields)
}

///|
fn sorted_pairs(values : Array[@model.KeyValue]) -> Array[@model.KeyValue] {
  let sorted = values.copy()
  sorted.sort_by((a, b) => @pathing.compare_utf8(a.key, b.key))
  sorted
}

///|
fn encode_string_array(values : Array[String]) -> String {
  array(values.map(value => quote(value)))
}

///|
fn add_optional_string(
  fields : Array[String],
  name : String,
  value : String?,
) -> Unit {
  match value {
    Some(value) => fields.push(field(name, quote(value)))
    None => ()
  }
}

///|
fn field(name : String, value : String) -> String {
  quote(name) + ":" + value
}

///|
fn quote(value : String) -> String {
  Json::string(value).stringify()
}

///|
fn object(fields : Array[String]) -> String {
  "{" + fields.join(",") + "}"
}

///|
fn array(values : Array[String]) -> String {
  "[" + values.join(",") + "]"
}
