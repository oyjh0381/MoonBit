///|
async fn compare_image_storage_command(args : Array[String]) -> Unit {
  if args.length() < 6 {
    raise @model.InvalidArgument(
      "usage: moonoci compare-image-storage BEFORE BEFORE_PIN AFTER AFTER_PIN [--require-runtime-identity] [--max-new-blob-bytes N]",
    )
  }
  let mut require_identity = false
  let mut budget : Int64? = None
  let mut before_index_pin : @model.Digest? = None
  let mut after_index_pin : @model.Digest? = None
  let mut offset = 6
  while offset < args.length() {
    match args[offset] {
      "--require-runtime-identity" if !require_identity =>
        require_identity = true
      "--max-new-blob-bytes" if offset + 1 < args.length() && budget is None => {
        offset += 1
        budget = Some(registry_byte_argument(args[offset]))
      }
      "--expect-before-index" if offset + 1 < args.length() &&
        before_index_pin is None => {
        offset += 1
        before_index_pin = Some(@model.Digest::parse(args[offset]))
      }
      "--expect-after-index" if offset + 1 < args.length() &&
        after_index_pin is None => {
        offset += 1
        after_index_pin = Some(@model.Digest::parse(args[offset]))
      }
      _ =>
        raise @model.InvalidArgument(
          "invalid or duplicate storage comparison option",
        )
    }
    offset += 1
  }
  let before_pin = @model.Digest::parse(args[3])
  let after_pin = @model.Digest::parse(args[5])
  let before = @native.load_bounded_layout(args[2])
  let after = @native.load_bounded_layout(args[4])
  let before_index = @digest.sha256(before.index())
  let after_index = @digest.sha256(after.index())
  if before_index_pin is Some(pin) && pin != before_index {
    raise @model.DigestMismatch(
      "storage comparison baseline index differs from its pin",
    )
  }
  if after_index_pin is Some(pin) && pin != after_index {
    raise @model.DigestMismatch(
      "storage comparison candidate index differs from its pin",
    )
  }
  let report = @builder.compare_image_storage(
    before, before_pin, after, after_pin,
  )
  let difference : Json = match report.first_layer_difference {
    None => Json::null()
    Some(change) =>
      {
        "position": Json::number(change.position.to_double()),
        "beforeDiffId": optional_diff_id(change.before_diff_id),
        "afterDiffId": optional_diff_id(change.after_diff_id),
      }
  }
  let identity_met = !require_identity || report.preserves_runtime_identity()
  let budget_met = match budget {
    None => true
    Some(limit) => report.new_image_blob_bytes <= limit
  }
  let result : Json = {
    "schema": "moonoci.image-storage-comparison.v1",
    "beforeManifest": Json::string(before_pin.to_string()),
    "afterManifest": Json::string(after_pin.to_string()),
    "beforeIndex": Json::string(before_index.to_string()),
    "afterIndex": Json::string(after_index.to_string()),
    "beforeConfig": Json::string(report.before_config.to_string()),
    "afterConfig": Json::string(report.after_config.to_string()),
    "preservesRuntimeIdentity": Json::boolean(
      report.preserves_runtime_identity(),
    ),
    "firstLayerDifference": difference,
    "beforeLayerBytes": Json::string(report.before_layer_bytes.to_string()),
    "afterLayerBytes": Json::string(report.after_layer_bytes.to_string()),
    "newLayerCount": Json::number(report.new_layer_count.to_double()),
    "newLayerBytes": Json::string(report.new_layer_bytes.to_string()),
    "beforeImageBlobBytes": Json::string(
      report.before_image_blob_bytes.to_string(),
    ),
    "afterImageBlobBytes": Json::string(
      report.after_image_blob_bytes.to_string(),
    ),
    "newImageBlobBytes": Json::string(report.new_image_blob_bytes.to_string()),
    "runtimeIdentityGatePassed": Json::boolean(identity_met),
    "transferBudgetGatePassed": Json::boolean(budget_met),
  }
  @stdio.stdout.write(result.stringify() + "\n")
  if !identity_met || !budget_met {
    process_exit(5)
  }
}

///|
fn optional_diff_id(value : @model.Digest?) -> Json {
  match value {
    None => Json::null()
    Some(digest) => Json::string(digest.to_string())
  }
}
