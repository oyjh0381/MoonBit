///|
test "tar writer and reader round trip deterministic entries" {
  let original = [
    TarEntry::directory("etc", mode=0o755),
    TarEntry::file("etc/config", b"answer=42\n", mode=0o640),
    TarEntry::symlink("bin/tool", "usr/bin/tool"),
  ]
  let parsed = read_tar(write_tar(original))
  assert_eq(parsed.length(), 3)
  assert_eq(parsed[0].path, "bin/tool")
  assert_eq(parsed[1].path, "etc")
  assert_eq(parsed[2].data, b"answer=42\n")
}

///|
test "tar reader resolves PAX long path" {
  let path = "deep/" + "z".repeat(130)
  let parsed = read_tar(write_tar([TarEntry::file(path, b"ok")]))
  assert_eq(parsed.length(), 1)
  assert_eq(parsed[0].path, path)
  assert_eq(parsed[0].data, b"ok")
}

///|
test "tar reader rejects checksum corruption" {
  let bytes = write_tar([TarEntry::file("file", b"data")]).to_array()
  bytes[0] = b'X'
  let corrupted = Bytes::from_array(bytes)
  let mut raised = false
  ignore(read_tar(corrupted)) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "tar reader rejects duplicate paths" {
  let first = write_tar([TarEntry::file("same", b"one")])
  let middle = write_tar([TarEntry::file("middle", b"value")])
  let last = write_tar([TarEntry::file("same", b"two")])
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
  ignore(read_tar(Bytes::from_array(combined))) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "tar reader rejects risky symlink target" {
  let mut raised = false
  ignore(TarEntry::symlink("link", "../../etc/passwd")) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "tar reader enforces entry limit" {
  let data = write_tar([TarEntry::file("a", b""), TarEntry::file("b", b"")])
  let mut raised = false
  ignore(read_tar(data, max_entries=1)) catch {
    _ => raised = true
  }
  assert_true(raised)
}
