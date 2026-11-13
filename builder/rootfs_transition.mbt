///|
/// One normalized effect applied by a Layer to the prior Root Filesystem.
priv enum RootfsTransition {
  Opaque(String)
  Remove(String)
  Add(@archive.TarEntry)
}

///|
fn has_whiteout_segment(path : String) -> Bool {
  for segment in path.split("/") {
    if segment.has_prefix(".wh.") {
      return true
    }
  }
  false
}

///|
fn declared_rootfs_transitions(
  layer : LayerBuildRequest,
) -> Array[RootfsTransition] raise @model.MoonOciError {
  let transitions : Array[RootfsTransition] = []
  for path in layer.remove {
    let normalized = @pathing.normalize_spec_path(path)
    if has_whiteout_segment(normalized) {
      raise @model.InvalidArgument(
        "cannot remove a reserved whiteout path: " + normalized,
      )
    }
    transitions.push(Remove(normalized))
  }
  for path in layer.opaque_dirs {
    let normalized = if path == "/" {
      ""
    } else {
      @pathing.normalize_spec_path(path)
    }
    if has_whiteout_segment(normalized) {
      raise @model.InvalidArgument(
        "cannot mark a reserved whiteout path opaque: " + normalized,
      )
    }
    transitions.push(Opaque(normalized))
  }
  for entry in layer.entries {
    if has_whiteout_segment(entry.path) {
      raise @model.InvalidArgument(
        "layer additions must not use reserved Whiteout paths: " + entry.path,
      )
    }
    transitions.push(Add(entry))
  }
  transitions
}

///|
fn archived_rootfs_transitions(
  entries : Array[@archive.TarEntry],
) -> Array[RootfsTransition] raise @model.MoonOciError {
  let transitions : Array[RootfsTransition] = []
  for entry in entries {
    let segments = entry.path.split("/").map(part => part.to_owned()).collect()
    let basename = segments[segments.length() - 1]
    for i in 0..<(segments.length() - 1) {
      if segments[i].has_prefix(".wh.") {
        raise @model.InvalidOci(
          "layer path descends from a reserved whiteout name: " + entry.path,
        )
      }
    }
    if basename == ".wh..wh..opq" {
      validate_whiteout_marker(entry)
      let directory = if segments.length() == 1 {
        ""
      } else {
        segments[0:segments.length() - 1].to_owned().join("/")
      }
      transitions.push(Opaque(directory))
    } else if basename.has_prefix(".wh.") {
      validate_whiteout_marker(entry)
      let target_name = basename[4:].to_owned()
      if target_name == "" {
        raise @model.InvalidOci("Whiteout target must not be empty")
      }
      let target = if segments.length() == 1 {
        target_name
      } else {
        segments[0:segments.length() - 1].to_owned().join("/") +
        "/" +
        target_name
      }
      ignore(@pathing.normalize_archive_path(target))
      if @pathing.is_whiteout_path(target) {
        raise @model.InvalidOci(
          "whiteout cannot target a reserved path: " + target,
        )
      }
      transitions.push(Remove(target))
    } else {
      transitions.push(Add(entry))
    }
  }
  transitions
}

///|
fn validate_whiteout_marker(
  entry : @archive.TarEntry,
) -> Unit raise @model.MoonOciError {
  if entry.kind != @archive.TarEntryKind::Regular ||
    entry.data.length() != 0 ||
    entry.link_target is Some(_) {
    raise @model.InvalidOci(
      "Whiteout and Opaque markers must be empty regular files: " + entry.path,
    )
  }
}

///|
fn RootfsNode::apply(
  root : RootfsNode,
  transitions : Array[RootfsTransition],
  layer_index : Int32,
  evidence_layer? : @model.Digest,
) -> Unit raise @model.MoonOciError {
  let opaque_paths : Array[String] = []
  let removed_paths : Array[String] = []
  let additions : Array[@archive.TarEntry] = []
  for transition in transitions {
    match transition {
      Opaque(path) => opaque_paths.push(path)
      Remove(path) => removed_paths.push(path)
      Add(entry) => additions.push(entry)
    }
  }
  opaque_paths.sort_by((a, b) => @pathing.compare_utf8(a, b))
  removed_paths.sort_by((a, b) => @pathing.compare_utf8(a, b))
  additions.sort_by((a, b) => @pathing.compare_utf8(a.path, b.path))
  for path in opaque_paths {
    if path.is_empty() {
      root.children.clear()
    } else if root.find_path(path) is Some(node) {
      node.children.clear()
    }
  }
  for path in removed_paths {
    match path.rev_find("/") {
      None => root.children.remove(path)
      Some(slash) =>
        if root.find_path(path[:slash].to_owned()) is Some(parent) {
          parent.children.remove(path[slash + 1:].to_owned())
        }
    }
  }
  for entry in additions {
    let node = root.ensure_path(entry.path)
    if entry.kind != Directory {
      node.children.clear()
    }
    let kind = match entry.kind {
      Regular => "file"
      Directory => "directory"
      Symlink => "symlink"
    }
    let observed : @model.RootfsEntry = {
      path: entry.path,
      kind,
      mode: entry.mode,
      size: entry.size(),
      link_target: entry.link_target,
      layer_index,
    }
    node.entry = Some(observed)
    node.evidence = evidence_layer.map(layer_digest => {
      entry: observed,
      layer_digest,
      content_digest: if entry.kind == Regular {
        Some(@digest.sha256(entry.data))
      } else {
        None
      },
      uid: entry.uid,
      gid: entry.gid,
      mtime: entry.mtime,
    })
  }
}

///|
fn[T] RootfsNode::collect(
  root : RootfsNode,
  value : (RootfsNode) -> T?,
) -> Array[T] {
  let result : Array[T] = []
  let pending = [root]
  while pending.pop() is Some(node) {
    if value(node) is Some(entry) {
      result.push(entry)
    }
    for _, child in node.children {
      pending.push(child)
    }
  }
  result
}

///|
fn RootfsNode::snapshot(root : RootfsNode) -> Array[@model.RootfsEntry] {
  let result = root.collect(node => node.entry)
  result.sort_by((a, b) => @pathing.compare_utf8(a.path, b.path))
  result
}

///|
priv struct RootfsNode {
  mut entry : @model.RootfsEntry?
  mut evidence : FileEvidence?
  children : Map[String, RootfsNode]
}

///|
fn RootfsNode::empty() -> RootfsNode {
  { entry: None, evidence: None, children: Map([]), }
}

///|
fn RootfsNode::find_path(self : RootfsNode, path : String) -> RootfsNode? {
  let mut node = self
  for segment in path.split("/") {
    match node.children.get(segment.to_owned()) {
      Some(child) => node = child
      None => return None
    }
  }
  Some(node)
}

///|
fn RootfsNode::ensure_path(
  self : RootfsNode,
  path : String,
) -> RootfsNode raise @model.MoonOciError {
  let mut node = self
  for segment in path.split("/") {
    if node.entry is Some(parent) && parent.kind != "directory" {
      raise @model.InvalidOci(
        "cannot add child beneath non-directory path: " + parent.path,
      )
    }
    let key = segment.to_owned()
    node = match node.children.get(key) {
      Some(child) => child
      None => {
        let child = RootfsNode::empty()
        node.children[key] = child
        child
      }
    }
  }
  node
}
