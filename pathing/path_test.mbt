///|
test "normalizes build-spec paths" {
  inspect(normalize_spec_path("/usr/bin/app"), content="usr/bin/app")
  inspect(normalize_archive_path("usr/bin/app"), content="usr/bin/app")
}

///|
test "generates whiteout paths" {
  inspect(whiteout_path("/etc/old.conf"), content="etc/.wh.old.conf")
  inspect(whiteout_path("obsolete"), content=".wh.obsolete")
  inspect(opaque_whiteout_path("/var/cache"), content="var/cache/.wh..wh..opq")
}

///|
test "flags risky symlink targets" {
  assert_true(symlink_target_is_risky("../../etc/passwd"))
  assert_true(symlink_target_is_risky("/etc/passwd"))
  assert_false(symlink_target_is_risky("safe"))
}

///|
test "UTF-8 comparator is lexicographic rather than shortlex" {
  assert_true(compare_utf8("bin/tool", "etc") < 0)
  assert_true(compare_utf8("a", "aa") < 0)
  assert_eq(compare_utf8("same", "same"), 0)
}
