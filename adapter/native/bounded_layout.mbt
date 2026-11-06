///|
pub(all) struct LayoutLoadLimits {
  max_blobs : Int32
  max_blob_bytes : Int32
  max_total_bytes : Int64
  max_index_bytes : Int32
}

///|
pub fn LayoutLoadLimits::default() -> LayoutLoadLimits {
  {
    max_blobs: 4096,
    max_blob_bytes: 268435456,
    max_total_bytes: 536870912L,
    max_index_bytes: 16777216,
  }
}

///|
pub fn LayoutLoadLimits::validate(
  self : LayoutLoadLimits,
) -> Unit raise @model.MoonOciError {
  if self.max_blobs < 1 ||
    self.max_blobs > 65536 ||
    self.max_blob_bytes < 1 ||
    self.max_blob_bytes > 536870912 ||
    self.max_total_bytes < 1L ||
    self.max_total_bytes > 8589934592L ||
    self.max_index_bytes < 1 ||
    self.max_index_bytes > 16777216 {
    raise @model.InvalidArgument("invalid bounded layout load limits")
  }
}

///|
async fn require_layout_kind(path : String, kind : @fs.FileKind) -> Unit {
  let actual = @fs.kind(path, follow_symlink=false) catch {
    error => raise @model.IoFailure("cannot inspect layout path: \{error}")
  }
  if actual != kind {
    raise @model.IoFailure(
      "layout path has unexpected kind or is a symlink: " + path,
    )
  }
}

///|
/// Preflight counts and aggregate sizes before allocating blob data. Streaming
/// directory enumeration is bounded. The returned layout still retains all bytes
/// in memory; limits do not prove RSS bounds or hostile-parent race isolation.
pub async fn load_bounded_layout(
  source : String,
  limits~ : LayoutLoadLimits = LayoutLoadLimits::default(),
) -> @layout.MemoryLayout {
  limits.validate()
  let marker_path = join_path(source, "oci-layout")
  let index_path = join_path(source, "index.json")
  let algorithms_path = join_path(source, "blobs")
  let blobs_path = join_path(source, "blobs/sha256")
  require_layout_kind(source, Directory)
  require_layout_kind(marker_path, Regular)
  require_layout_kind(index_path, Regular)
  require_layout_kind(algorithms_path, Directory)
  require_layout_kind(blobs_path, Directory)
  let algorithms = @fs.opendir(algorithms_path) catch {
    error =>
      raise @model.IoFailure("cannot enumerate blob algorithms: \{error}")
  }
  {
    defer algorithms.close()
    while (algorithms.next(include_hidden=true, include_special=false) catch {
            error =>
              raise @model.IoFailure(
                "cannot enumerate blob algorithms: \{error}",
              )
          })
          is Some(entry) {
      if entry.name != "sha256" {
        raise @model.Unsupported(
          "bounded layout loader supports only the sha256 blob directory",
        )
      }
    }
  }
  let marker_budget = if limits.max_total_bytes < 4096L {
    limits.max_total_bytes.to_int()
  } else {
    4096
  }
  let marker = read_bounded_file(marker_path, marker_budget)
  let remaining = limits.max_total_bytes - marker.length().to_int64()
  if remaining < 1L {
    raise @model.ResourceLimitExceeded(
      "no input budget remains for the root index",
    )
  }
  let index_budget = if remaining < limits.max_index_bytes.to_int64() {
    remaining.to_int()
  } else {
    limits.max_index_bytes
  }
  let index = read_bounded_file(index_path, index_budget)
  let mut total = marker.length().to_int64() + index.length().to_int64()
  if total > limits.max_total_bytes {
    raise @model.ResourceLimitExceeded(
      "layout metadata exceeds total input quota",
    )
  }
  let entries : Array[(@model.Digest, Int32)] = []
  let directory = @fs.opendir(blobs_path) catch {
    error => raise @model.IoFailure("cannot enumerate layout blobs: \{error}")
  }
  {
    defer directory.close()
    while (directory.next(include_hidden=true, include_special=false) catch {
            error =>
              raise @model.IoFailure("cannot enumerate layout blobs: \{error}")
          })
          is Some(entry) {
      if entries.length() == limits.max_blobs {
        raise @model.ResourceLimitExceeded("layout blob count quota exceeded")
      }
      let digest = @model.Digest::sha256(entry.name)
      let path = join_path(blobs_path, entry.name)
      require_layout_kind(path, Regular)
      let file = @fs.open(path, mode=ReadOnly) catch {
        error => raise @model.IoFailure("cannot stat layout blob: \{error}")
      }
      let size = {
        defer file.close()
        file.size() catch {
          error => raise @model.IoFailure("cannot size layout blob: \{error}")
        }
      }
      if size < 0L ||
        size > limits.max_blob_bytes.to_int64() ||
        size > limits.max_total_bytes - total {
        raise @model.ResourceLimitExceeded(
          "layout blob/aggregate byte quota exceeded before reading content",
        )
      }
      total += size
      entries.push((digest, size.to_int()))
    }
  }
  entries.sort_by((a, b) => a.0.to_string().compare(b.0.to_string()))
  let records = []
  for (digest, size) in entries {
    let path = join_path(source, digest.blob_path())
    require_layout_kind(path, Regular)
    let bytes = read_bounded_file(path, if size == 0 { 1 } else { size })
    if bytes.length() != size {
      raise @model.IoFailure("layout blob size changed after preflight")
    }
    let descriptor : @model.Descriptor = {
      media_type: "",
      digest,
      size: size.to_int64(),
      annotations: [],
      platform: None,
    }
    records.push((descriptor, bytes))
  }
  @layout.MemoryLayout::from_untrusted_parts(marker, index, records)
}
