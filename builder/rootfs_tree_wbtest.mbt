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

///|
test "hardlink replay preserves captured content and metadata after target replacement" {
  let tree = RootfsNode::empty()
  let original = {
    ..@archive.TarEntry::file("original", b"payload", mode=0o600),
    uid: 19,
  }
  let linked = {
    ..@archive.TarEntry::file("alias", b""),
    kind: @archive.Hardlink,
    link_target: Some("original"),
  }
  let chain = { ..linked, path: "chain", link_target: Some("alias"), }
  let base = @digest.sha256(b"base")
  tree.apply([Add(original), Add(linked), Add(chain)], 0, evidence_layer=base)
  tree.apply(
    [Add(@archive.TarEntry::file("original", b"replacement"))],
    1,
    evidence_layer=@digest.sha256(b"upper"),
  )
  for path in ["alias", "chain"] {
    let file = tree.find_path(path).unwrap().evidence.unwrap()
    assert_eq(file.entry.kind, "hardlink")
    assert_eq(file.entry.mode, 0o600)
    assert_eq(file.entry.size, 7L)
    assert_eq(file.uid, 19)
    assert_eq(file.content_digest, Some(@digest.sha256(b"payload")))
    assert_eq(file.layer_digest, base)
  }
}

///|
test "hardlink replay requires an earlier same-layer regular target" {
  let linked = {
    ..@archive.TarEntry::file("alias", b""),
    kind: @archive.Hardlink,
    link_target: Some("target"),
  }
  for
    transitions in [
      [Add(linked), Add(@archive.TarEntry::file("target", b"late"))],
      [Add(@archive.TarEntry::directory("target")), Add(linked)],
      [Add(@archive.TarEntry::symlink("target", "other")), Add(linked)],
    ] {
    let denied = try {
      RootfsNode::empty().apply(transitions, 0)
      false
    } catch {
      @model.InvalidOci(_) => true
      _ => false
    }
    assert_true(denied)
  }
}
