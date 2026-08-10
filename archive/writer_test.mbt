///|
test "deterministic tar is independent of input order" {
  let a = TarEntry::file("etc/config", b"value")
  let b = TarEntry::directory("etc")
  let first = write_tar([a, b])
  let second = write_tar([b, a])
  assert_eq(first, second)
  assert_eq(first.length() % 512, 0)
  assert_true(first.length() >= 2048)
}

///|
test "tar supports PAX long paths" {
  let path = "segment/" + "a".repeat(120)
  let data = write_tar([TarEntry::file(path, b"x")])
  assert_true(data.length() >= 2560)
  assert_true(bytes_contains(data, @utf8.encode("path=" + path)))
}

///|
test "tar encodes whiteouts" {
  let data = write_tar([
    TarEntry::whiteout("/etc/old.conf"),
    TarEntry::opaque_marker("/var/cache"),
  ])
  assert_true(bytes_contains(data, b"etc/.wh.old.conf"))
  assert_true(bytes_contains(data, b"var/cache/.wh..wh..opq"))
}

///|
test "tar writer revalidates raw public entry values" {
  let invalid_entry : TarEntry = {
    path: "../escape",
    kind: Regular,
    mode: 0o644,
    uid: 0,
    gid: 0,
    mtime: 0L,
    data: b"payload",
    link_target: None,
  }
  let mut raised = false
  ignore(write_tar([invalid_entry])) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
fn bytes_contains(haystack : Bytes, needle : Bytes) -> Bool {
  if needle.length() == 0 {
    return true
  }
  if needle.length() > haystack.length() {
    return false
  }
  for start in 0..<=(haystack.length() - needle.length()) {
    let mut matches = true
    for offset in 0..<needle.length() {
      if haystack[start + offset] != needle[offset] {
        matches = false
        break
      }
    }
    if matches {
      return true
    }
  }
  false
}
