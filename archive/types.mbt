///|
/// File kind encoded in a layer tar header.
pub(all) enum TarEntryKind {
  Regular
  Directory
  Symlink
} derive(Debug, Eq)

///|
/// Complete deterministic input for one tar entry.
pub(all) struct TarEntry {
  path : String
  kind : TarEntryKind
  mode : Int
  uid : Int
  gid : Int
  mtime : Int64
  data : Bytes
  link_target : String?
} derive(Debug, Eq)

///|
/// Construct a normalized regular file entry.
pub fn TarEntry::file(
  path : String,
  data : Bytes,
  mode? : Int = 0o644,
) -> TarEntry raise @model.MoonOciError {
  {
    path: @pathing.normalize_archive_path(path),
    kind: Regular,
    mode,
    uid: 0,
    gid: 0,
    mtime: 0L,
    data,
    link_target: None,
  }
}

///|
/// Construct a normalized directory entry.
pub fn TarEntry::directory(
  path : String,
  mode? : Int = 0o755,
) -> TarEntry raise @model.MoonOciError {
  {
    path: @pathing.normalize_archive_path(path),
    kind: Directory,
    mode,
    uid: 0,
    gid: 0,
    mtime: 0L,
    data: b"",
    link_target: None,
  }
}

///|
/// Construct a symlink without following its target.
pub fn TarEntry::symlink(
  path : String,
  target : String,
) -> TarEntry raise @model.MoonOciError {
  @pathing.validate_symlink_target(target)
  {
    path: @pathing.normalize_archive_path(path),
    kind: Symlink,
    mode: 0o777,
    uid: 0,
    gid: 0,
    mtime: 0L,
    data: b"",
    link_target: Some(target),
  }
}

///|
/// Construct an empty whiteout file for a removed rootfs path.
pub fn TarEntry::whiteout(path : String) -> TarEntry raise @model.MoonOciError {
  TarEntry::file(@pathing.whiteout_path(path), b"", mode=0o000)
}

///|
/// Construct an opaque directory whiteout marker.
pub fn TarEntry::opaque_marker(
  path : String,
) -> TarEntry raise @model.MoonOciError {
  TarEntry::file(@pathing.opaque_whiteout_path(path), b"", mode=0o000)
}

///|
/// Size encoded in the tar header for this entry kind.
pub fn TarEntry::size(self : TarEntry) -> Int64 {
  match self.kind {
    Regular => self.data.length().to_int64()
    Directory | Symlink => 0L
  }
}
