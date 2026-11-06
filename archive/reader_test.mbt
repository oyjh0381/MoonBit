///|
test "tar writer and reader round trip deterministic entries" {
  let original = [
    @archive.TarEntry::directory("etc", mode=0o755),
    @archive.TarEntry::file("etc/config", b"answer=42\n", mode=0o640),
    @archive.TarEntry::symlink("bin/tool", "usr/bin/tool"),
  ]
  let parsed = @archive.read_tar(@archive.write_tar(original))
  assert_eq(parsed.length(), 3)
  assert_eq(parsed[0].path, "bin/tool")
  assert_eq(parsed[1].path, "etc")
  assert_eq(parsed[2].data, b"answer=42\n")
}

///|
test "tar reader resolves PAX long path" {
  let path = "deep/" + "z".repeat(130)
  let parsed = @archive.read_tar(
    @archive.write_tar([@archive.TarEntry::file(path, b"ok")]),
  )
  assert_eq(parsed.length(), 1)
  assert_eq(parsed[0].path, path)
  assert_eq(parsed[0].data, b"ok")
}

///|
test "tar reader rejects checksum corruption" {
  let bytes = @archive.write_tar([@archive.TarEntry::file("file", b"data")]).to_array()
  bytes[0] = b'X'
  let corrupted = Bytes::from_array(bytes)
  let mut raised = false
  ignore(@archive.read_tar(corrupted)) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "tar reader rejects duplicate paths" {
  let first = @archive.write_tar([@archive.TarEntry::file("same", b"one")])
  let middle = @archive.write_tar([@archive.TarEntry::file("middle", b"value")])
  let last = @archive.write_tar([@archive.TarEntry::file("same", b"two")])
  let combined : Array[Byte] = []
  for archive in [first, middle, last] {
    for i in 0..<1024 {
      combined.push(archive[i])
    }
  }
  for _ in 0..<1024 {
    combined.push(b'\x00')
  }
  let mut raised = false
  ignore(@archive.read_tar(Bytes::from_array(combined))) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "tar reader rejects risky symlink target" {
  let mut raised = false
  ignore(@archive.TarEntry::symlink("link", "../../etc/passwd")) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "tar reader enforces entry limit" {
  let data = @archive.write_tar([
    @archive.TarEntry::file("a", b""),
    @archive.TarEntry::file("b", b""),
  ])
  let mut raised = false
  ignore(@archive.read_tar(data, max_entries=1)) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "PAX record length cannot overflow or exceed its payload" {
  let path = "deep/" + "z".repeat(130)
  let malformed = @archive.write_tar([@archive.TarEntry::file(path, b"")]).to_array()
  let mut cursor = 512
  while malformed[cursor] != b' ' {
    malformed[cursor] = b'9'
    cursor += 1
  }
  let mut raised = false
  ignore(@archive.read_tar(Bytes::from_array(malformed))) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "tar reader rejects GNU sparse PAX metadata" {
  let path = "deep/" + "z".repeat(130)
  let output = @archive.write_tar([@archive.TarEntry::file(path, b"")]).to_array()
  let original = @utf8.encode("path=")
  let replacement = @utf8.encode("GNU.sparse.map=")
  let mut key_offset = -1
  for i in 512..<(1024 - replacement.length()) {
    let mut matches = true
    for j in 0..<original.length() {
      if output[i + j] != original[j] {
        matches = false
      }
    }
    if matches {
      key_offset = i
      break
    }
  }
  assert_true(key_offset >= 0)
  for i in 0..<replacement.length() {
    output[key_offset + i] = replacement[i]
  }
  let mut raised = false
  ignore(@archive.read_tar(Bytes::from_array(output))) catch {
    _ => raised = true
  }
  assert_true(raised)
}
