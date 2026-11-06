///|
test "path security matrix rejects traversal and host-specific absolute forms" {
  let unsafe_cases = [
    "", ".", "..", "../x", "x/..", "x/../y", "./x", "x/./y", "/../x", "//server/share",
    "///root", "C:/Windows", "c:/temp", "Z:relative", "a\\b", "\\server\\share",
    "x//y", "/x//y", "x/", "/", "./", "../", "a/../../b", "a/.hidden/..", "NUL\u{0000}x",
    "D:\\data", "//", "a///b", "/C:/host", "relative\\child",
  ]
  for value in unsafe_cases {
    let mut raised = false
    ignore(@pathing.normalize_spec_path(value)) catch {
      _ => raised = true
    }
    assert_true(raised, msg="expected unsafe path rejection: " + value)
  }
}

///|
test "path security matrix accepts normalized portable forms" {
  let safe = [
    "a", "a/b", "/a", "/a/b", ".hidden", "a/.hidden", "space name", "unicode/目录",
    "dash-name", "under_score", "123", "a+b", "a=b", "a,b", "a@b", "a#b", "a%b",
    "a(b)", "a[b]", "a{b}", "a!b", "a~b", "a'b", "a;b", "a&b", "a$b", "a😀b", "é",
    "日本語", "one/two/three",
  ]
  for value in safe {
    let normalized = @pathing.normalize_spec_path(value)
    assert_false(normalized.has_prefix("/"))
    assert_false(normalized.contains("\\"))
    assert_false(normalized.contains(".."))
  }
}

///|
test "property: accepted paths are idempotent and archive-safe" {
  @quickcheck.quick_check_fn((value : String) => {
    try {
      let normalized = @pathing.normalize_spec_path(value)
      @pathing.normalize_archive_path(normalized) == normalized &&
      @pathing.normalize_spec_path(normalized) == normalized &&
      !normalized.has_prefix("/") &&
      !normalized.contains("\\")
    } catch {
      _ => true
    }
  })
}
