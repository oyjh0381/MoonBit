///|
test "indexed transitions isolate prefix siblings and enforce symlink parents" {
  let first = apply_rootfs_transitions(
    [],
    [
      Add(@archive.TarEntry::file("data/implicit/leaf", b"old")),
      Add(@archive.TarEntry::file("database/keep", b"keep")),
    ],
    0,
  )
  let result = apply_rootfs_transitions(
    first,
    [Add(@archive.TarEntry::symlink("data", "replacement"))],
    1,
  )
  assert_eq(result.map(entry => entry.path), ["data", "database/keep"])
  let rejected = try {
    ignore(
      apply_rootfs_transitions(
        result,
        [Add(@archive.TarEntry::file("data/child", b"x"))],
        2,
      ),
    )
    false
  } catch {
    @model.InvalidOci(_) => true
    _ => false
  }
  assert_true(rejected)
  let reset = apply_rootfs_transitions(
    result,
    [Opaque(""), Add(@archive.TarEntry::file("data/child", b"new"))],
    2,
  )
  assert_eq(reset.map(entry => entry.path), ["data/child"])
}
