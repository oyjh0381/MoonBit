///|
test "indexed transitions isolate prefix siblings and enforce symlink parents" {
  let tree = RootfsNode::empty()
  tree.apply(
    [
      Add(@archive.TarEntry::file("data/implicit/leaf", b"old")),
      Add(@archive.TarEntry::file("database/keep", b"keep")),
    ],
    0,
  )
  tree.apply([Add(@archive.TarEntry::symlink("data", "replacement"))], 1)
  assert_eq(tree.snapshot().map(entry => entry.path), ["data", "database/keep"])
  let rejected = try {
    ignore(tree.apply([Add(@archive.TarEntry::file("data/child", b"x"))], 2))
    false
  } catch {
    @model.InvalidOci(_) => true
    _ => false
  }
  assert_true(rejected)
  tree.apply(
    [Opaque(""), Add(@archive.TarEntry::file("data/child", b"new"))],
    2,
  )
  assert_eq(tree.snapshot().map(entry => entry.path), ["data/child"])
}
