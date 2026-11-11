///|
pub(all) struct RebaseResult {
  layout : @layout.MemoryLayout
  manifest : @model.Descriptor
  plan : RebasePlan
}

///|
fn json_fields(data : Bytes) -> Map[String, Json] raise @model.MoonOciError {
  guard @codec.parse_json_document(data, preserve_number_repr=true)
    is Object(fields) else {
    raise @model.InvalidOci("rebase metadata must be a JSON object")
  }
  fields
}

///|
fn history_items(
  fields : Map[String, Json],
  layer_count : Int32,
) -> Array[Json]? raise @model.MoonOciError {
  match fields.get("history") {
    None => None
    Some(Array(items)) => {
      let mut layers = 0
      for item in items {
        guard item is Object(entry) else {
          raise @model.InvalidOci("rebase history entry must be an object")
        }
        match entry.get("empty_layer") {
          Some(True) => ()
          Some(False) | None => layers += 1
          _ =>
            raise @model.InvalidOci(
              "rebase history empty_layer must be a boolean",
            )
        }
      }
      if layers != layer_count {
        raise @model.InvalidOci(
          "rebase history does not cover every layer exactly once",
        )
      }
      Some(items)
    }
    _ => raise @model.InvalidOci("rebase history must be an array")
  }
}

///|
fn rewrite_config(
  app : Map[String, Json],
  old : Map[String, Json],
  replacement : Map[String, Json],
  plan : RebasePlan,
  app_count : Int32,
  replacement_count : Int32,
) -> Bytes raise @model.MoonOciError {
  let app_history = history_items(app, app_count)
  let old_history = history_items(old, plan.removed_layers)
  let new_history = history_items(replacement, replacement_count)
  match (app_history, old_history, new_history) {
    (None, None, None) => ()
    (Some(full), Some(prefix), Some(next)) => {
      if prefix.length() > full.length() {
        raise @model.InvalidOci(
          "previous base history exceeds application history",
        )
      }
      for i, item in prefix {
        if item != full[i] {
          raise @model.InvalidOci(
            "previous base history is not an exact application prefix",
          )
        }
      }
      app["history"] = Json::array(next + full[prefix.length():].to_owned())
    }
    _ =>
      raise @model.InvalidOci(
        "rebase requires consistent history presence in all three inputs",
      )
  }
  guard app.get("rootfs") is Some(Object(rootfs)) else {
    raise @model.InvalidOci("rebase application has no rootfs metadata")
  }
  rootfs["diff_ids"] = Json::array(
    plan.layers.map(layer => Json::string(layer.diff_id.to_string())),
  )
  @utf8.encode(Json::object(app).stringify())
}

///|
fn layer_items(
  fields : Map[String, Json],
) -> Array[Json] raise @model.MoonOciError {
  guard fields.get("layers") is Some(Array(items)) else {
    raise @model.InvalidOci("rebase manifest layers must be an array")
  }
  items
}

///|
/// Create a new OCI image by applying a verified base replacement. Existing
/// image bytes and subject attachments are unaffected by materialization.
pub fn rebase_image(
  application : @layout.MemoryLayout,
  previous_base : @layout.MemoryLayout,
  replacement_base : @layout.MemoryLayout,
  pins : RebasePins,
  reference : String,
  replacement_name? : String,
) -> RebaseResult raise @model.MoonOciError {
  if reference.is_empty() ||
    reference.length() > 255 ||
    reference.contains_char('\u{0000}') {
    raise @model.InvalidArgument("invalid rebased image reference")
  }
  if replacement_name is Some(name) &&
    (name.is_empty() || name.length() > 4096 || name.contains_char('\u{0000}')) {
    raise @model.InvalidArgument("invalid replacement base name")
  }
  let app = load_image(application, pins.application)
  let old = load_image(previous_base, pins.previous_base)
  let replacement = load_image(replacement_base, pins.replacement_base)
  let plan = plan_inputs(app, old, replacement, pins)
  let app_config = json_fields(application.require_blob(app.manifest.config))
  let old_config = json_fields(previous_base.require_blob(old.manifest.config))
  let new_config = json_fields(
    replacement_base.require_blob(replacement.manifest.config),
  )
  let config_bytes = rewrite_config(
    app_config,
    old_config,
    new_config,
    plan,
    app.manifest.layers.length(),
    replacement.manifest.layers.length(),
  )
  let app_raw = json_fields(application.get_blob(pins.application).unwrap())
  let new_raw = json_fields(
    replacement_base.get_blob(pins.replacement_base).unwrap(),
  )
  if app_raw.contains("subject") || app_raw.contains("artifactType") {
    raise @model.Unsupported(
      "rebasing a subject-bound or typed artifact is unsupported",
    )
  }
  let raw_layers = layer_items(new_raw) +
    layer_items(app_raw)[plan.removed_layers:].to_owned()
  let annotations : Map[String, Json] = match app_raw.get("annotations") {
    Some(Object(fields)) => fields
    _ => Map([])
  }
  annotations.remove("org.opencontainers.image.base.name")
  if replacement_name is Some(name) {
    annotations["org.opencontainers.image.base.name"] = Json::string(name)
  }
  annotations["org.opencontainers.image.base.digest"] = Json::string(
    pins.replacement_base.to_string(),
  )
  app_raw["annotations"] = Json::object(annotations)

  let layout = @layout.MemoryLayout::new()
  for layer in plan.layers {
    let source = if layer.from_replacement {
      replacement_base
    } else {
      application
    }
    let bytes = source.get_blob(layer.descriptor.digest).unwrap()
    ignore(layout.put_blob(layer.descriptor.media_type, bytes))
  }
  let config = layout.put_blob(@model.media_type_config, config_bytes)
  app_raw["config"] = @codec.parse_json_document(
    @utf8.encode(@codec.encode_descriptor(config)),
  )
  app_raw["layers"] = Json::array(raw_layers)
  let manifest = layout.put_blob(
    @model.media_type_manifest,
    @utf8.encode(Json::object(app_raw).stringify()),
    annotations=[{ key: @model.annotation_ref_name, value: reference, }],
    platform=plan.platform,
  )
  layout.set_index(
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests: [manifest],
      annotations: [],
    }),
  )
  ignore(@builder.rootfs_from_manifest(layout, manifest))
  { layout, manifest, plan, }
}
