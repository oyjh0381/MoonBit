///|
/// Build a Native OCI Image Layout from a Build Specification file.
pub async fn build_from_file(spec_path : String) -> @builder.ImageBuildResult {
  if !@fs.exists(spec_path) {
    raise @model.IoFailure("Build Specification does not exist: " + spec_path)
  }
  let spec = @spec.parse_build_spec(@fs.read_file(spec_path).binary())
  let layers : Array[@builder.LayerBuildRequest] = []
  for layer in spec.layers {
    let entries = collect_layer_source(layer.source, layer)
    layers.push({
      entries,
      remove: layer.remove,
      opaque_dirs: layer.opaque_dirs,
      compression: layer.compression,
    })
  }
  let result = @builder.build_image({
    layers,
    platform: spec.platform,
    runtime: spec.runtime,
    created: resolve_created(spec.created),
    author: spec.author,
    reference: spec.reference,
    annotations: spec.annotations,
  })
  write_layout(spec.output.layout, result.layout)
  result
}

///|
fn resolve_created(explicit : String?) -> String? raise @model.MoonOciError {
  match explicit {
    Some(value) => Some(value)
    None =>
      match @env.get_env_var("SOURCE_DATE_EPOCH") {
        Some(value) => Some(source_date_epoch_to_created(value))
        None => None
      }
  }
}

///|
fn source_date_epoch_to_created(
  value : String,
) -> String raise @model.MoonOciError {
  let seconds = @string.parse_int64(value) catch {
    _ =>
      raise @model.InvalidBuildSpec(
        "SOURCE_DATE_EPOCH must be a non-negative integer",
      )
  }
  if seconds < 0L {
    raise @model.InvalidBuildSpec(
      "SOURCE_DATE_EPOCH must be a non-negative integer",
    )
  }
  @time.unix(seconds).to_string() catch {
    _ => raise @model.InvalidBuildSpec("SOURCE_DATE_EPOCH is out of range")
  }
}

///|
test "SOURCE_DATE_EPOCH converts to canonical UTC creation time" {
  assert_eq(source_date_epoch_to_created("0"), "1970-01-01T00:00:00Z")
}

///|
/// Materialize an in-memory layout through a staging directory and rename.
pub async fn write_layout(
  destination : String,
  layout : @layout.MemoryLayout,
  buffered~ : Bool = false,
) -> Unit {
  if destination == "" {
    raise @model.InvalidArgument("layout destination must not be empty")
  }
  if @fs.exists(destination) {
    raise @model.IoFailure("layout destination already exists: " + destination)
  }
  let staging = destination + ".moonoci-staging"
  if @fs.exists(staging) {
    raise @model.IoFailure("staging destination already exists: " + staging)
  }
  // Validate uniqueness and canonical digests before deriving any file path.
  let marker = layout.marker()
  let index = layout.index()
  let records = layout.blob_records()
  let seen : Map[String, Bool] = Map([])
  for blob in records {
    let descriptor = blob.descriptor()
    let key = descriptor.digest.to_string()
    ignore(@model.Digest::parse(key))
    if seen.contains(key) {
      raise @model.InvalidOci("duplicate physical Blob during materialization")
    }
    seen[key] = true
    if descriptor.size != blob.data().length().to_int64() {
      raise @model.SizeMismatch("materialized Blob size mismatch")
    }
    if @digest.sha256(blob.data()) != descriptor.digest {
      raise @model.DigestMismatch("materialized Blob SHA-256 mismatch")
    }
  }
  let sync : @fs.SyncMode = if buffered { NoSync } else { Data }
  try {
    @fs.mkdir(join_path(staging, "blobs/sha256"), recursive=true)
    @fs.write_file(
      join_path(staging, "oci-layout"),
      marker,
      create_mode=CreateNew,
      sync~,
    )
    @fs.write_file(
      join_path(staging, "index.json"),
      index,
      create_mode=CreateNew,
      sync~,
    )
    for blob in records {
      @fs.write_file(
        join_path(staging, blob.descriptor().digest.blob_path()),
        blob.data(),
        create_mode=CreateNew,
        sync~,
      )
    }
    @fs.rename(staging, destination, replace=false)
  } catch {
    error => {
      if @fs.exists(staging) {
        @fs.rmdir(staging, recursive=true) catch {
          _ => ()
        }
      }
      raise @model.IoFailure("cannot write OCI Image Layout: \{error}")
    }
  }
}
