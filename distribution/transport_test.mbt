///|
test "transfer archive roundtrip is deterministic and hydrates offline" {
  let base = image("amd64", b"hello")
  let target = image("arm64", b"hello")
  let envelope = @distribution.create_delta(base, target)
  let wire = @distribution.encode_delta(envelope)
  let decoded = @distribution.decode_delta(wire)
  assert_eq(wire, @distribution.encode_delta(decoded))
  let hydrated = @distribution.hydrate(
    base,
    decoded,
    @digest.sha256(target.index()),
  )
  assert_eq(hydrated.index(), target.index())
  assert_true(@builder.verify_memory(hydrated).is_valid())
}

///|
test "transfer archives reject extra members and symlinks without extraction" {
  let base = image("amd64", b"hello")
  let wire = @distribution.encode_delta(@distribution.create_delta(base, base))
  let entries = @archive.read_tar(wire)
  for
    extra in [
      @archive.TarEntry::file("extra", b"x"),
      @archive.TarEntry::symlink("link", "index.json"),
    ] {
    let modified = entries.copy()
    modified.push(extra)
    let rejected = try {
      ignore(@distribution.decode_delta(@archive.write_tar(modified)))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}
