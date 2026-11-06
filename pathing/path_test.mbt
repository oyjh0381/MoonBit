///|
test "normalizes build-spec paths" {
  inspect(@pathing.normalize_spec_path("/usr/bin/app"), content="usr/bin/app")
  inspect(@pathing.normalize_archive_path("usr/bin/app"), content="usr/bin/app")
}

///|
test "generates whiteout paths" {
  inspect(@pathing.whiteout_path("/etc/old.conf"), content="etc/.wh.old.conf")
  inspect(@pathing.whiteout_path("obsolete"), content=".wh.obsolete")
  inspect(
    @pathing.opaque_whiteout_path("/var/cache"),
    content="var/cache/.wh..wh..opq",
  )
}

///|
test "flags risky symlink targets" {
  assert_true(@pathing.symlink_target_is_risky("../../etc/passwd"))
  assert_true(@pathing.symlink_target_is_risky("/etc/passwd"))
  assert_true(@pathing.symlink_target_is_risky("C:/Windows"))
  assert_true(@pathing.symlink_target_is_risky("c:relative-on-drive"))
  assert_false(@pathing.symlink_target_is_risky("safe"))
}

///|
test "UTF-8 comparator is lexicographic rather than shortlex" {
  assert_true(@pathing.compare_utf8("bin/tool", "etc") < 0)
  assert_true(@pathing.compare_utf8("a", "aa") < 0)
  assert_eq(@pathing.compare_utf8("same", "same"), 0)
}
