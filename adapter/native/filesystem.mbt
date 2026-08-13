///|
/// Read a Layer Source directory while rejecting symlinks observed by traversal.
/// The filesystem API cannot make kind-check and file-read one atomic operation;
/// callers must provide a trusted, quiescent source tree while a build runs.
pub async fn collect_layer_source(
  source : String,
  layer : @spec.LayerSpec,
) -> Array[@archive.TarEntry] {
  if !@fs.exists(source) {
    raise @model.IoFailure("layer source does not exist: " + source)
  }
  if @fs.kind(source, follow_symlink=false) != @fs.FileKind::Directory {
    raise @model.InvalidBuildSpec("layer source must be a directory: " + source)
  }
  let patterns = layer.exclude.copy()
  match layer.ignore_file {
    Some(name) => {
      if name.contains("/") || name.contains("\\") || name == "" {
        raise @model.InvalidBuildSpec(
          "ignoreFile must name a file in the Layer Source root",
        )
      }
      let path = join_path(source, name)
      if @fs.exists(path) {
        let text = @fs.read_file(path).text()
        for line in text.split("\n") {
          let pattern = line.trim().to_owned()
          if pattern != "" && !pattern.has_prefix("#") {
            patterns.push(pattern)
          }
        }
        patterns.push(name)
      }
    }
    None => ()
  }
  let entries : Array[@archive.TarEntry] = []
  collect_directory(source, "", patterns, layer.metadata, entries)
  entries
}

///|
async fn collect_directory(
  current : String,
  relative : String,
  patterns : Array[String],
  metadata : @spec.MetadataSpec,
  entries : Array[@archive.TarEntry],
) -> Unit {
  let names = @fs.readdir(
    current,
    include_hidden=true,
    include_special=false,
    sort=true,
  )
  for name in names {
    let archive_path = if relative == "" { name } else { relative + "/" + name }
    if is_excluded(patterns, archive_path) {
      continue
    }
    let full_path = join_path(current, name)
    match @fs.kind(full_path, follow_symlink=false) {
      Directory => {
        let entry = @archive.TarEntry::directory(archive_path)
        entries.push(apply_metadata(entry, full_path, metadata))
        collect_directory(full_path, archive_path, patterns, metadata, entries)
      }
      Regular => {
        let data = @fs.read_file(full_path).binary()
        if @fs.kind(full_path, follow_symlink=false) != @fs.FileKind::Regular {
          raise @model.IoFailure(
            "Layer Source entry changed while being read: " + archive_path,
          )
        }
        let entry = @archive.TarEntry::file(archive_path, data)
        entries.push(apply_metadata(entry, full_path, metadata))
      }
      SymLink =>
        raise @model.Unsupported(
          "Native Layer Source symlink import is unavailable in v0.1: " +
          archive_path,
        )
      Unknown | Socket | Pipe | BlockDevice | CharDevice =>
        raise @model.Unsupported(
          "unsupported Layer Source entry: " + archive_path,
        )
    }
  }
}

///|
async fn apply_metadata(
  entry : @archive.TarEntry,
  full_path : String,
  metadata : @spec.MetadataSpec,
) -> @archive.TarEntry {
  let default_mode = entry.mode
  let mode = metadata.mode.unwrap_or(default_mode)
  let uid = metadata.uid.unwrap_or(0)
  let gid = metadata.gid.unwrap_or(0)
  let mtime = match metadata.mtime {
    Some(value) => value
    None if metadata.preserve_mtime =>
      @fs.mtime(full_path, follow_symlink=false).0
    None => 0L
  }
  { ..entry, mode, uid, gid, mtime }
}

///|
fn join_path(parent : String, child : String) -> String {
  if parent.has_suffix("/") || parent.has_suffix("\\") {
    parent + child
  } else {
    parent + "/" + child
  }
}

///|
fn is_excluded(patterns : Array[String], path : String) -> Bool {
  for pattern in patterns {
    let normalized = if pattern.has_prefix("/") {
      pattern[1:].to_owned()
    } else {
      pattern
    }
    if wildcard_match(normalized, path) ||
      (normalized.has_suffix("/") && path.has_prefix(normalized)) {
      return true
    }
  }
  false
}

///|
/// Match `*` and `?` deterministically against UTF-8 bytes. `*` may cross `/`.
fn wildcard_match(pattern : String, value : String) -> Bool {
  let p = @utf8.encode(pattern)
  let v = @utf8.encode(value)
  let mut pi = 0
  let mut vi = 0
  let mut star = -1
  let mut retry = 0
  while vi < v.length() {
    if pi < p.length() && (p[pi] == b'?' || p[pi] == v[vi]) {
      pi += 1
      vi += 1
    } else if pi < p.length() && p[pi] == b'*' {
      star = pi
      retry = vi
      pi += 1
    } else if star >= 0 {
      pi = star + 1
      retry += 1
      vi = retry
    } else {
      return false
    }
  }
  while pi < p.length() && p[pi] == b'*' {
    pi += 1
  }
  pi == p.length()
}
