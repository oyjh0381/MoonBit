///|
fn layer_headers(
  headers : Array[(String, Byte, String)],
) -> Bytes raise @model.MoonOciError {
  let bytes : Array[Byte] = []
  for (name, flag, target) in headers {
    let header = make_header(name, 0o755, 0, 0, 0L, 0L, flag, target)
    for byte in header {
      bytes.push(byte)
    }
  }
  for _ in 0..<1024 {
    bytes.push(b'\x00')
  }
  Bytes::from_array(bytes)
}

///|
test "OCI layer reader preserves container links and normalizes directory suffixes" {
  let wire = layer_headers([
    ("bin/", b'5', ""),
    ("bin/sh", b'2', "/bin/busybox"),
  ])
  let entries = read_layer_tar(wire)
  assert_eq(entries[0].path, "bin")
  assert_eq(entries[1].link_target, Some("/bin/busybox"))
  let strict = try {
    ignore(read_tar(wire))
    false
  } catch {
    _ => true
  }
  assert_true(strict)
  let link_only = layer_headers([("bin/sh", b'2', "/bin/busybox")])
  let strict = try {
    ignore(read_tar(link_only))
    false
  } catch {
    _ => true
  }
  assert_true(strict)
}

///|
test "OCI directory suffix normalization cannot admit duplicate or unsafe entry paths" {
  for
    headers in [
      [("bin/", b'5', ""), ("bin", b'5', "")],
      [("/bin/", b'5', "")],
      [("../bin/", b'5', "")],
      [("bin//", b'5', "")],
      [("file/", b'0', "")],
    ] {
    let rejected = try {
      ignore(read_layer_tar(layer_headers(headers)))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "OCI reader accepts tar -C root . paths while keeping aliases unique" {
  let entries = read_layer_tar(
    layer_headers([
      ("./", b'5', ""),
      ("./bin/", b'5', ""),
      ("./bin/tool", b'0', ""),
    ]),
  )
  assert_eq(entries.map(entry => entry.path), ["bin", "bin/tool"])
  for
    names in [
      ["./", "."],
      ["./bin", "bin"],
      ["./../bin", "file"],
      ["././bin", "file"],
    ] {
    let kind = if names[0] == "./" { b'5' } else { b'0' }
    let rejected = try {
      ignore(read_layer_tar(layer_headers(names.map(name => (name, kind, "")))))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "tar octal fields reject digits after a field terminator" {
  assert_eq(read_octal(b" 00007 \x00", 0, 8, "mode"), 7L)
  for field in [b"1 2", b"1\x002", b"\x001"] {
    let rejected = try {
      ignore(read_octal(field, 0, field.length(), "size"))
      false
    } catch {
      @model.InvalidTar(_) => true
      _ => false
    }
    assert_true(rejected)
  }
}
