///|
let default_max_entries : Int32 = 1_000_000

///|
/// Parse a tar layer into normalized entries while enforcing safety limits.
/// Supports USTAR, POSIX PAX path/linkpath records, and GNU long name/link
/// records. Sparse files and special device-like entries are rejected.
pub fn read_tar(
  data : Bytes,
  max_entries~ : Int32 = default_max_entries,
  max_path_bytes~ : Int32 = @pathing.max_path_bytes,
) -> Array[TarEntry] raise @model.MoonOciError {
  read_tar_impl(data, max_entries, max_path_bytes, layer=false)
}

///|
/// Read an OCI filesystem changeset for in-memory interpretation. Directory
/// names may have a trailing slash and paths may start with ./ . A root
/// directory header is consumed without emitting a named entry. Symlink targets are opaque container
/// metadata and must never be resolved on the host filesystem.
pub fn read_layer_tar(
  data : Bytes,
  max_entries~ : Int32 = default_max_entries,
  max_path_bytes~ : Int32 = @pathing.max_path_bytes,
) -> Array[TarEntry] raise @model.MoonOciError {
  read_tar_impl(data, max_entries, max_path_bytes, layer=true)
}

///|
fn read_tar_impl(
  data : Bytes,
  max_entries : Int32,
  max_path_bytes : Int32,
  layer~ : Bool,
) -> Array[TarEntry] raise @model.MoonOciError {
  if max_entries <= 0 || max_path_bytes <= 0 {
    raise @model.InvalidArgument("tar limits must be positive")
  }
  if data.length() < tar_block_size * 2 || data.length() % tar_block_size != 0 {
    raise @model.InvalidTar(
      "tar size must be a multiple of 512 with an end marker",
    )
  }
  let entries : Array[TarEntry] = []
  let mut offset = 0
  let mut zero_blocks = 0
  let mut root_header_seen = false
  let mut pending_path : String? = None
  let mut pending_link : String? = None
  while offset + tar_block_size <= data.length() && zero_blocks < 2 {
    if block_is_zero(data, offset) {
      zero_blocks += 1
      offset += tar_block_size
      continue
    }
    if zero_blocks != 0 {
      raise @model.InvalidTar("tar has an isolated zero end block")
    }
    validate_checksum(data, offset)
    let header_name = read_text(data, offset, 100, "name")
    let prefix = read_text(data, offset + 345, 155, "prefix")
    let header_path = if prefix == "" {
      header_name
    } else {
      prefix + "/" + header_name
    }
    let mode = read_tar_int(data, offset + 100, 8, "mode")
    let uid = read_tar_int(data, offset + 108, 8, "uid")
    let gid = read_tar_int(data, offset + 116, 8, "gid")
    let size64 = read_tar_number(data, offset + 124, 12, "size")
    let mtime = read_tar_number(data, offset + 136, 12, "mtime")
    if size64 > data.length().to_int64() {
      raise @model.InvalidTar("tar entry size exceeds archive length")
    }
    let size = size64.to_int()
    let content_start = offset + tar_block_size
    if content_start > data.length() || size > data.length() - content_start {
      raise @model.InvalidTar("truncated tar entry payload")
    }
    let padding = (tar_block_size - size % tar_block_size) % tar_block_size
    if padding > data.length() - content_start - size {
      raise @model.InvalidTar("truncated tar entry padding")
    }
    let next = content_start + size + padding
    let typeflag = data[offset + 156]
    if typeflag == b'x' {
      let records = parse_pax(data, content_start, size)
      for record in records {
        if record.key.has_prefix("GNU.sparse.") {
          raise @model.Unsupported("GNU sparse PAX entries are not supported")
        } else if record.key == "path" {
          pending_path = Some(record.value)
        } else if record.key == "linkpath" {
          pending_link = Some(record.value)
        }
      }
    } else if typeflag == b'L' {
      pending_path = Some(
        read_long_text(data, content_start, size, "GNU long name"),
      )
    } else if typeflag == b'K' {
      pending_link = Some(
        read_long_text(data, content_start, size, "GNU long link"),
      )
    } else {
      let raw_path = pending_path.unwrap_or(header_path)
      if layer && typeflag == b'5' && (raw_path == "." || raw_path == "./") {
        if root_header_seen ||
          size != 0 ||
          pending_link.unwrap_or(read_text(data, offset + 157, 100, "linkname")) !=
          "" {
          raise @model.InvalidTar(
            "invalid or duplicate OCI root directory header",
          )
        }
        root_header_seen = true
        pending_path = None
        pending_link = None
        offset = next
        continue
      }
      let raw_path = if layer && raw_path.has_prefix("./") {
        raw_path[2:].to_owned()
      } else {
        raw_path
      }
      let raw_path = if layer && typeflag == b'5' && raw_path.has_suffix("/") {
        raw_path[0:raw_path.length() - 1].to_owned()
      } else {
        raw_path
      }
      let path = @pathing.normalize_archive_path(raw_path)
      if @utf8.encode(path).length() > max_path_bytes {
        raise @model.ResourceLimitExceeded("tar path exceeds configured limit")
      }
      let header_link = read_text(data, offset + 157, 100, "linkname")
      let raw_link = pending_link.unwrap_or(header_link)
      let kind = match typeflag {
        b'\x00' | b'0' => Regular
        b'5' => Directory
        b'2' => Symlink
        b'S' =>
          raise @model.Unsupported("GNU sparse tar entries are not supported")
        other =>
          raise @model.Unsupported(
            "unsupported tar typeflag: " + other.to_int().to_string(),
          )
      }
      if kind != Regular && size != 0 {
        raise @model.InvalidTar("non-regular tar entry must have zero size")
      }
      let payload = if kind == Regular {
        copy_bytes(data, content_start, size)
      } else {
        b""
      }
      let link_target = if kind == Symlink {
        if raw_link == "" {
          raise @model.InvalidTar("symlink entry has an empty target")
        }
        let target_bytes = @utf8.encode(raw_link).length()
        if target_bytes > max_path_bytes ||
          target_bytes > @pathing.max_path_bytes {
          raise @model.ResourceLimitExceeded(
            "symlink target exceeds configured limit",
          )
        }
        if raw_link.contains_char('\u{0000}') {
          raise @model.InvalidPath("symlink target must not contain NUL")
        }
        if !layer {
          @pathing.validate_symlink_target(raw_link)
        }
        Some(raw_link)
      } else {
        None
      }
      entries.push({
        path,
        kind,
        mode,
        uid,
        gid,
        mtime,
        data: payload,
        link_target,
      })
      if entries.length() > max_entries {
        raise @model.ResourceLimitExceeded(
          "tar entry count exceeds configured limit",
        )
      }
      pending_path = None
      pending_link = None
    }
    offset = next
  }
  if zero_blocks < 2 {
    raise @model.InvalidTar("tar is missing two zero end blocks")
  }
  for index in offset..<data.length() {
    if data[index] != b'\x00' {
      raise @model.InvalidTar("tar has nonzero data after the end marker")
    }
  }
  if pending_path is Some(_) || pending_link is Some(_) {
    raise @model.InvalidTar("dangling tar extension record")
  }
  validate_unique_paths(entries)
  entries
}

///|
fn block_is_zero(data : Bytes, offset : Int32) -> Bool {
  for i in 0..<tar_block_size {
    if data[offset + i] != b'\x00' {
      return false
    }
  }
  true
}

///|
fn validate_checksum(
  data : Bytes,
  offset : Int32,
) -> Unit raise @model.MoonOciError {
  let expected = read_octal(data, offset + 148, 8, "checksum")
  let mut actual = 0L
  for i in 0..<tar_block_size {
    actual += if i >= 148 && i < 156 {
      32L
    } else {
      data[offset + i].to_int64()
    }
  }
  if actual != expected {
    raise @model.InvalidTar("tar header checksum mismatch")
  }
}

///|
fn read_tar_int(
  data : Bytes,
  offset : Int32,
  width : Int32,
  field : String,
) -> Int32 raise @model.MoonOciError {
  let value = read_tar_number(data, offset, width, field)
  if value > 2147483647L {
    raise @model.ResourceLimitExceeded("tar Int32 field overflow: " + field)
  }
  value.to_int()
}

///|
// GNU tar uses a leading 0x80 marker for a positive base-256 value.
fn read_tar_number(
  data : Bytes,
  offset : Int32,
  width : Int32,
  field : String,
) -> Int64 raise @model.MoonOciError {
  if data[offset] != b'\x80' {
    return read_octal(data, offset, width, field)
  }
  let mut value = 0L
  for i in 1..<width {
    let digit = data[offset + i].to_int64()
    if value > (0x7fffffffffffffffL - digit) / 256L {
      raise @model.ResourceLimitExceeded(
        "tar base-256 field overflow: " + field,
      )
    }
    value = value * 256L + digit
  }
  value
}

///|
fn read_octal(
  data : Bytes,
  offset : Int32,
  width : Int32,
  field : String,
) -> Int64 raise @model.MoonOciError {
  let mut value = 0L
  let mut seen = false
  let mut terminated = false
  for i in 0..<width {
    let byte = data[offset + i]
    if byte == b'\x00' || (byte == b' ' && seen) {
      terminated = true
      continue
    }
    if byte == b' ' {
      continue
    }
    if terminated || byte < b'0' || byte > b'7' {
      raise @model.InvalidTar("invalid octal tar " + field)
    }
    let digit = (byte - b'0').to_int64()
    if value > (0x7fffffffffffffffL - digit) / 8L {
      raise @model.ResourceLimitExceeded("tar numeric field overflow: " + field)
    }
    value = value * 8L + digit
    seen = true
  }
  if seen {
    value
  } else {
    0L
  }
}

///|
fn read_text(
  data : Bytes,
  offset : Int32,
  width : Int32,
  field : String,
) -> String raise @model.MoonOciError {
  let mut length = 0
  while length < width && data[offset + length] != b'\x00' {
    length += 1
  }
  decode_utf8(data, offset, length, field)
}

///|
fn read_long_text(
  data : Bytes,
  offset : Int32,
  length : Int32,
  field : String,
) -> String raise @model.MoonOciError {
  let mut actual = length
  while actual > 0 && data[offset + actual - 1] == b'\x00' {
    actual -= 1
  }
  decode_utf8(data, offset, actual, field)
}

///|
fn decode_utf8(
  data : Bytes,
  offset : Int32,
  length : Int32,
  field : String,
) -> String raise @model.MoonOciError {
  @utf8.decode(data[offset:offset + length]) catch {
    _ => raise @model.InvalidTar("invalid UTF-8 in tar " + field)
  }
}

///|
fn copy_bytes(data : Bytes, offset : Int32, length : Int32) -> Bytes {
  let output = Array::make(length, b'\x00')
  for i in 0..<length {
    output[i] = data[offset + i]
  }
  Bytes::from_array(output)
}

///|
fn parse_pax(
  data : Bytes,
  offset : Int32,
  size : Int32,
) -> Array[@model.KeyValue] raise @model.MoonOciError {
  let records : Array[@model.KeyValue] = []
  let mut cursor = 0
  while cursor < size {
    let start = cursor
    let mut record_length = 0
    let maximum_record_length = size - start
    while cursor < size && data[offset + cursor] != b' ' {
      let byte = data[offset + cursor]
      if byte < b'0' || byte > b'9' {
        raise @model.InvalidTar("invalid PAX record length")
      }
      let digit = (byte - b'0').to_int()
      if record_length > (maximum_record_length - digit) / 10 {
        raise @model.InvalidTar("PAX record length exceeds payload")
      }
      record_length = record_length * 10 + digit
      cursor += 1
    }
    if cursor >= size || record_length <= 0 || record_length > size - start {
      raise @model.InvalidTar("truncated PAX record")
    }
    cursor += 1
    let body_start = cursor
    let body_end = start + record_length
    if body_end <= body_start || data[offset + body_end - 1] != b'\n' {
      raise @model.InvalidTar("PAX record is missing newline")
    }
    let mut equals = body_start
    while equals < body_end - 1 && data[offset + equals] != b'=' {
      equals += 1
    }
    if equals == body_start || equals >= body_end - 1 {
      raise @model.InvalidTar("invalid PAX key/value record")
    }
    let key = decode_utf8(
      data,
      offset + body_start,
      equals - body_start,
      "PAX key",
    )
    let value = decode_utf8(
      data,
      offset + equals + 1,
      body_end - equals - 2,
      "PAX value",
    )
    records.push({ key, value, })
    cursor = body_end
  }
  records
}
