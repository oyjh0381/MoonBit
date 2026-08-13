///|
/// One normalized effect applied by a Layer to the prior Root Filesystem.
priv enum RootfsTransition {
  Opaque(String)
  Remove(String)
  Add(@archive.TarEntry)
}

///|
fn declared_rootfs_transitions(
  layer : LayerBuildRequest,
) -> Array[RootfsTransition] raise @model.MoonOciError {
  let transitions : Array[RootfsTransition] = []
  let removed_paths : Array[String] = []
  let opaque_paths : Array[String] = []
  for path in layer.remove {
    let normalized = @pathing.normalize_spec_path(path)
    removed_paths.push(normalized)
    transitions.push(Remove(normalized))
  }
  for path in layer.opaque_dirs {
    let normalized = @pathing.normalize_spec_path(path)
    opaque_paths.push(normalized)
    transitions.push(Opaque(normalized))
  }
  for removed in removed_paths {
    for opaque_path in opaque_paths {
      if removed == opaque_path {
        raise @model.InvalidArgument(
          "layer cannot remove and mark the same path opaque: " + removed,
        )
      }
    }
  }
  for entry in layer.entries {
    if @pathing.is_whiteout_path(entry.path) {
      raise @model.InvalidArgument(
        "layer additions must not use reserved Whiteout paths: " + entry.path,
      )
    }
    for removed in removed_paths {
      if entry.path == removed {
        raise @model.InvalidArgument(
          "layer cannot add and remove the same path: " + removed,
        )
      }
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
  let additions : Array[String] = []
  let removals : Array[String] = []
  let opaques : Array[String] = []
  for entry in entries {
    let segments = entry.path.split("/").map(part => part.to_owned()).collect()
    let basename = segments[segments.length() - 1]
    if basename == ".wh..wh..opq" {
      validate_whiteout_marker(entry)
      let directory = if segments.length() == 1 {
        ""
      } else {
        segments[0:segments.length() - 1].to_owned().join("/")
      }
      opaques.push(directory)
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
      removals.push(target)
      transitions.push(Remove(target))
    } else {
      additions.push(entry.path)
      transitions.push(Add(entry))
    }
  }
  for removed in removals {
    for added in additions {
      if removed == added {
        raise @model.InvalidOci(
          "Layer contains conflicting add and Whiteout transitions: " + removed,
        )
      }
    }
    for opaque_path in opaques {
      if removed == opaque_path {
        raise @model.InvalidOci(
          "Layer contains conflicting Whiteout and Opaque transitions: " +
          removed,
        )
      }
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
fn apply_rootfs_transitions(
  current : Array[@model.RootfsEntry],
  transitions : Array[RootfsTransition],
  layer_index : Int,
) -> Array[@model.RootfsEntry] raise @model.MoonOciError {
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
  let mut result = current
  for path in opaque_paths {
    result = if path == "" { [] } else { filter_children(result, path, true) }
  }
  for path in removed_paths {
    result = filter_children(result, path, false)
  }
  for entry in additions {
    validate_parent_chain(result, entry.path)
    result = match entry.kind {
      Directory => filter_exact(result, entry.path)
      Regular | Symlink => filter_children(result, entry.path, false)
    }
    let kind = match entry.kind {
      Regular => "file"
      Directory => "directory"
      Symlink => "symlink"
    }
    result.push({
      path: entry.path,
      kind,
      mode: entry.mode,
      size: entry.size(),
      link_target: entry.link_target,
      layer_index,
    })
  }
  result.sort_by((a, b) => @pathing.compare_utf8(a.path, b.path))
  result
}

///|
fn filter_exact(
  entries : Array[@model.RootfsEntry],
  path : String,
) -> Array[@model.RootfsEntry] {
  entries.filter(entry => entry.path != path)
}

///|
fn filter_children(
  entries : Array[@model.RootfsEntry],
  path : String,
  keep_parent : Bool,
) -> Array[@model.RootfsEntry] {
  let result : Array[@model.RootfsEntry] = []
  let prefix = path + "/"
  for entry in entries {
    let remove = entry.path.has_prefix(prefix) ||
      (!keep_parent && entry.path == path)
    if !remove {
      result.push(entry)
    }
  }
  result
}

///|
fn validate_parent_chain(
  entries : Array[@model.RootfsEntry],
  path : String,
) -> Unit raise @model.MoonOciError {
  let segments = path.split("/").map(part => part.to_owned()).collect()
  for end in 1..<segments.length() {
    let parent = segments[0:end].to_owned().join("/")
    for existing in entries {
      if existing.path == parent && existing.kind != "directory" {
        raise @model.InvalidOci(
          "cannot add child beneath non-directory path: " + parent,
        )
      }
    }
  }
}
