///|
pub let max_path_bytes : Int = 4096

///|
/// Compare strings by encoded UTF-8 bytes. MoonBit's built-in String
/// comparison is shortlex, which is not the archive ordering MoonOCI promises.
pub fn compare_utf8(left : String, right : String) -> Int {
  let a = @utf8.encode(left)
  let b = @utf8.encode(right)
  let shared = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<shared {
    if a[i] < b[i] {
      return -1
    }
    if a[i] > b[i] {
      return 1
    }
  }
  a.length().compare(b.length())
}

///|
/// Validate and normalize a relative path that will be stored in a layer tar.
pub fn normalize_archive_path(
  input : String,
) -> String raise @model.MoonOciError {
  normalize(input, allow_root_prefix=false)
}

///|
/// Normalize a root-relative path from the build specification.
/// A single leading slash is accepted for user convenience and removed.
pub fn normalize_spec_path(input : String) -> String raise @model.MoonOciError {
  normalize(input, allow_root_prefix=true)
}

///|
fn normalize(
  input : String,
  allow_root_prefix~ : Bool,
) -> String raise @model.MoonOciError {
  if input == "" {
    raise @model.InvalidPath("path must not be empty")
  }
  if @utf8.encode(input).length() > max_path_bytes {
    raise @model.ResourceLimitExceeded("path exceeds 4096 UTF-8 bytes")
  }
  if input.contains_char('\u{0000}') {
    raise @model.InvalidPath("path must not contain NUL")
  }
  if input.contains("\\") {
    raise @model.InvalidPath("archive paths must use forward slashes")
  }
  if input.has_prefix("//") {
    raise @model.InvalidPath("UNC paths are not allowed")
  }
  let mut value = input
  if value.has_prefix("/") {
    if !allow_root_prefix {
      raise @model.InvalidPath("absolute archive paths are not allowed")
    }
    value = value[1:].to_owned()
  }
  if value.length() >= 2 {
    let bytes = @utf8.encode(value)
    let first = bytes[0].to_int()
    let drive_letter = (first >= 65 && first <= 90) ||
      (first >= 97 && first <= 122)
    if drive_letter && bytes[1] == b':' {
      raise @model.InvalidPath("drive-letter paths are not allowed")
    }
  }
  let segments : Array[String] = []
  for view in value.split("/") {
    let segment = view.to_owned()
    if segment == "" {
      raise @model.InvalidPath("path must not contain empty segments")
    }
    if segment == "." || segment == ".." {
      raise @model.InvalidPath("path must not contain dot segments")
    }
    segments.push(segment)
  }
  if segments.length() == 0 {
    raise @model.InvalidPath("path resolves to an empty value")
  }
  segments.join("/")
}

///|
/// Return the OCI whiteout path corresponding to a removed rootfs path.
pub fn whiteout_path(input : String) -> String raise @model.MoonOciError {
  let path = normalize_spec_path(input)
  match path.split_once("/") {
    None => ".wh." + path
    Some(_) => {
      let segments = path.split("/").map(v => v.to_owned()).collect()
      let basename = segments[segments.length() - 1]
      let parent = segments[0:segments.length() - 1].to_owned().join("/")
      parent + "/.wh." + basename
    }
  }
}

///|
/// Return the OCI opaque marker path for a rootfs directory.
pub fn opaque_whiteout_path(input : String) -> String raise @model.MoonOciError {
  normalize_spec_path(input) + "/.wh..wh..opq"
}

///|
/// Determine whether a symlink target deserves a strict-mode portability warning.
pub fn symlink_target_is_risky(target : String) -> Bool {
  if target.has_prefix("/") || target.has_prefix("\\") || target.contains("\\") {
    return true
  }
  let encoded = @utf8.encode(target)
  if encoded.length() >= 2 &&
    encoded[1] == b':' &&
    (
      (encoded[0] >= b'A' && encoded[0] <= b'Z') ||
      (encoded[0] >= b'a' && encoded[0] <= b'z')
    ) {
    return true
  }
  for segment in target.split("/") {
    if segment == ".." {
      return true
    }
  }
  false
}

///|
/// Reject link targets that can escape a root filesystem or vary by host OS.
pub fn validate_symlink_target(
  target : String,
) -> Unit raise @model.MoonOciError {
  if target == "" {
    raise @model.InvalidPath("symlink target must not be empty")
  }
  if @utf8.encode(target).length() > max_path_bytes {
    raise @model.ResourceLimitExceeded(
      "symlink target exceeds 4096 UTF-8 bytes",
    )
  }
  if target.contains_char('\u{0000}') {
    raise @model.InvalidPath("symlink target must not contain NUL")
  }
  if symlink_target_is_risky(target) {
    raise @model.InvalidPath(
      "symlink target must be a safe forward-slash relative path",
    )
  }
}

///|
/// Whether a path uses the OCI Whiteout namespace reserved by MoonOCI.
pub fn is_whiteout_path(path : String) -> Bool {
  let segments = path.split("/").map(part => part.to_owned()).collect()
  segments[segments.length() - 1].has_prefix(".wh.")
}
