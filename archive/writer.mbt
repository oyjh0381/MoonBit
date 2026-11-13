///|
let tar_block_size : Int32 = 512

///|
/// Build a deterministic uncompressed layer tar.
pub fn write_tar(entries : Array[TarEntry]) -> Bytes raise @model.MoonOciError {
  let sorted = entries.copy()
  sorted.sort_by((a, b) => @pathing.compare_utf8(a.path, b.path))
  validate_unique_paths(sorted)
  let output : Array[Byte] = []
  for entry in sorted {
    validate_entry(entry)
    write_entry(output, entry)
  }
  append_zeros(output, tar_block_size * 2)
  Bytes::from_array(output)
}

///|
fn validate_unique_paths(
  entries : Array[TarEntry],
) -> Unit raise @model.MoonOciError {
  let paths = entries.map(entry => entry.path)
  paths.sort_by((a, b) => @pathing.compare_utf8(a, b))
  for i in 1..<paths.length() {
    if paths[i - 1] == paths[i] {
      raise @model.InvalidTar("duplicate tar path: " + paths[i])
    }
  }
}

///|
fn validate_entry(entry : TarEntry) -> Unit raise @model.MoonOciError {
  if @pathing.normalize_archive_path(entry.path) != entry.path {
    raise @model.InvalidTar("tar entry path must already be normalized")
  }
  match entry.kind {
    Regular =>
      if entry.link_target is Some(_) {
        raise @model.InvalidTar("regular tar entry must not have a link target")
      }
    Directory =>
      if entry.data.length() != 0 || entry.link_target is Some(_) {
        raise @model.InvalidTar(
          "directory tar entry must not contain data or a link target",
        )
      }
    Symlink => {
      if entry.data.length() != 0 {
        raise @model.InvalidTar("symlink tar entry must not contain data")
      }
      match entry.link_target {
        Some(target) => @pathing.validate_symlink_target(target)
        None => raise @model.InvalidTar("symlink tar entry requires a target")
      }
    }
  }
}

///|
fn write_entry(
  output : Array[Byte],
  entry : TarEntry,
) -> Unit raise @model.MoonOciError {
  let path_bytes = @utf8.encode(entry.path)
  let link = entry.link_target.unwrap_or("")
  let link_bytes = @utf8.encode(link)
  let pax_records : Array[String] = []
  if path_bytes.length() > 100 {
    pax_records.push(pax_record("path", entry.path))
  }
  if link_bytes.length() > 100 {
    pax_records.push(pax_record("linkpath", link))
  }
  let uid = pax_owner_field("uid", entry.uid, pax_records)
  let gid = pax_owner_field("gid", entry.gid, pax_records)
  if pax_records.length() > 0 {
    let pax_data = @utf8.encode(pax_records.join(""))
    let pax_header = make_header(
      "PaxHeaders/moonoci",
      0o644,
      0,
      0,
      pax_data.length().to_int64(),
      0L,
      b'x',
      "",
    )
    append_fixed(output, pax_header)
    append_bytes(output, pax_data)
    append_padding(output, pax_data.length())
  }
  let header_path = if path_bytes.length() <= 100 {
    entry.path
  } else {
    "PaxEntry"
  }
  let header_link = if link_bytes.length() <= 100 { link } else { "" }
  let typeflag = match entry.kind {
    Regular => b'0'
    Directory => b'5'
    Symlink => b'2'
  }
  let header = make_header(
    header_path,
    entry.mode,
    uid,
    gid,
    entry.size(),
    entry.mtime,
    typeflag,
    header_link,
  )
  append_fixed(output, header)
  if entry.kind == Regular {
    append_bytes(output, entry.data)
    append_padding(output, entry.data.length())
  }
}

///|
fn pax_owner_field(
  key : String,
  value : Int32,
  records : Array[String],
) -> Int32 {
  // The USTAR field holds seven octal digits plus its terminator.
  if value <= 0o7777777 {
    return value
  }
  records.push(pax_record(key, value.to_string()))
  0
}

///|
fn make_header(
  path : String,
  mode : Int32,
  uid : Int32,
  gid : Int32,
  size : Int64,
  mtime : Int64,
  typeflag : Byte,
  link_target : String,
) -> FixedArray[Byte] raise @model.MoonOciError {
  if mode < 0 || uid < 0 || gid < 0 || size < 0L || mtime < 0L {
    raise @model.InvalidTar("negative tar header values are not supported")
  }
  let header = FixedArray::make(tar_block_size, b'\x00')
  write_text(header, 0, 100, path)
  write_octal(header, 100, 8, mode.to_int64())
  write_octal(header, 108, 8, uid.to_int64())
  write_octal(header, 116, 8, gid.to_int64())
  write_octal(header, 124, 12, size)
  write_octal(header, 136, 12, mtime)
  for i in 148..<156 {
    header[i] = b' '
  }
  header[156] = typeflag
  write_text(header, 157, 100, link_target)
  write_raw(header, 257, b"ustar\x00")
  write_raw(header, 263, b"00")
  let mut checksum = 0
  for b in header {
    checksum += b.to_int()
  }
  write_checksum(header, checksum)
  header
}

///|
fn write_text(
  output : FixedArray[Byte],
  offset : Int32,
  width : Int32,
  value : String,
) -> Unit raise @model.MoonOciError {
  let encoded = @utf8.encode(value)
  if encoded.length() > width {
    raise @model.InvalidTar("tar text field exceeds fixed width")
  }
  for i in 0..<encoded.length() {
    output[offset + i] = encoded[i]
  }
}

///|
fn write_raw(output : FixedArray[Byte], offset : Int32, value : Bytes) -> Unit {
  for i in 0..<value.length() {
    output[offset + i] = value[i]
  }
}

///|
fn write_octal(
  output : FixedArray[Byte],
  offset : Int32,
  width : Int32,
  value : Int64,
) -> Unit raise @model.MoonOciError {
  let digits = value.to_string(radix=8)
  if digits.length() + 1 > width {
    raise @model.InvalidTar("numeric value does not fit tar octal field")
  }
  let padding = width - digits.length() - 1
  for i in 0..<padding {
    output[offset + i] = b'0'
  }
  write_raw(output, offset + padding, @utf8.encode(digits))
  output[offset + width - 1] = b'\x00'
}

///|
fn write_checksum(output : FixedArray[Byte], value : Int32) -> Unit {
  let digits = value.to_string(radix=8)
  let padding = 6 - digits.length()
  for i in 0..<padding {
    output[148 + i] = b'0'
  }
  write_raw(output, 148 + padding, @utf8.encode(digits))
  output[154] = b'\x00'
  output[155] = b' '
}

///|
fn pax_record(key : String, value : String) -> String {
  let body = key + "=" + value + "\n"
  let body_len = @utf8.encode(body).length()
  let mut total = body_len + 2
  let mut candidate = total.to_string() + " " + body
  for _ in 0..<16 {
    candidate = total.to_string() + " " + body
    let actual = @utf8.encode(candidate).length()
    if actual == total {
      return candidate
    }
    total = actual
  }
  candidate
}

///|
fn append_fixed(output : Array[Byte], data : FixedArray[Byte]) -> Unit {
  for b in data {
    output.push(b)
  }
}

///|
fn append_bytes(output : Array[Byte], data : Bytes) -> Unit {
  for b in data {
    output.push(b)
  }
}

///|
fn append_padding(output : Array[Byte], size : Int32) -> Unit {
  let remainder = size % tar_block_size
  if remainder != 0 {
    append_zeros(output, tar_block_size - remainder)
  }
}

///|
fn append_zeros(output : Array[Byte], count : Int32) -> Unit {
  for _ in 0..<count {
    output.push(b'\x00')
  }
}
