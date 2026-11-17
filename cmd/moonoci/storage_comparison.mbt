///|
async fn compare_image_storage_command(args : Array[String]) -> Unit {
  require_arity(
    args, 6, "usage: moonoci compare-image-storage BEFORE BEFORE_PIN AFTER AFTER_PIN",
  )
  let before_pin = @model.Digest::parse(args[3])
  let after_pin = @model.Digest::parse(args[5])
  let before = @native.load_bounded_layout(args[2])
  let after = @native.load_bounded_layout(args[4])
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
  let result : Json = {
    "schema": "moonoci.image-storage-comparison.v1",
    "beforeManifest": Json::string(before_pin.to_string()),
    "afterManifest": Json::string(after_pin.to_string()),
    "beforeIndex": Json::string(@digest.sha256(before.index()).to_string()),
    "afterIndex": Json::string(@digest.sha256(after.index()).to_string()),
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
  }
  @stdio.stdout.write(result.stringify() + "\n")
}

///|
fn optional_diff_id(value : @model.Digest?) -> Json {
  match value {
    None => Json::null()
    Some(digest) => Json::string(digest.to_string())
  }
}
