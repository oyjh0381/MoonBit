///|
/// Construct a hardlink to an archive-relative regular file.
pub fn TarEntry::hardlink(
  path : String,
  target : String,
) -> TarEntry raise @model.MoonOciError {
  {
    ..TarEntry::file(path, b""),
    kind: Hardlink,
    link_target: Some(@pathing.normalize_archive_path(target)),
  }
}

///|
// Input is sorted by UTF-8 path and has already passed entry validation.
// Emit ordinary entries first, then place each link after its dependency.
fn hardlink_tar_order(
  sorted : Array[TarEntry],
) -> Array[TarEntry] raise @model.MoonOciError {
  let all : Map[String, TarEntry] = Map([])
  let ordered : Array[TarEntry] = []
  let emitted : Map[String, Bool] = Map([])
  for entry in sorted {
    all[entry.path] = entry
    if entry.kind != Hardlink {
      ordered.push(entry)
    }
  }
  for entry in sorted {
    if entry.kind != Hardlink || emitted.contains(entry.path) {
      continue
    }
    let dependencies : Array[TarEntry] = []
    let mut cursor = entry
    while cursor.kind == Hardlink {
      match emitted.get(cursor.path) {
        Some(true) => break
        Some(false) =>
          raise @model.InvalidTar("cyclic tar hardlink at " + cursor.path)
        None => ()
      }
      let target = cursor.link_target.unwrap()
      guard all.get(target) is Some(source) &&
        (source.kind == Regular || source.kind == Hardlink) else {
        raise @model.InvalidTar(
          "tar hardlink target must be a same-layer regular file: " + target,
        )
      }
      emitted[cursor.path] = false
      dependencies.push(cursor)
      cursor = source
    }
    while dependencies.pop() is Some(link) {
      ordered.push(link)
      emitted[link.path] = true
    }
  }
  ordered
}
