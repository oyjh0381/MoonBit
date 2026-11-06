///|
fn snapshot(
  entries : Array[@archive.TarEntry],
  compression~ : @model.Compression = @model.Uncompressed,
) -> @builder.ImageBuildResult raise @model.MoonOciError {
  @builder.build_image({
    layers: [{ entries, remove: [], opaque_dirs: [], compression, }],
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "test",
    annotations: [],
  })
}

///|
test "same size file modifications are detected by final content" {
  let a = snapshot([
    @archive.TarEntry::file("same-size", b"old"),
    @archive.TarEntry::file("gone", b"x"),
  ])
  let b = snapshot([
    @archive.TarEntry::file("same-size", b"new"),
    @archive.TarEntry::file("added", b"x"),
  ])
  let compared = @review.compare_files(
    a.layout,
    a.report.manifest,
    b.layout,
    b.report.manifest,
  )
  assert_eq(compared.added, 1)
  assert_eq(compared.removed, 1)
  assert_eq(compared.modified, 1)
  assert_eq(compared.changes.map(c => c.path), ["added", "gone", "same-size"])
  assert_true(compared.changes[2].content_changed)
  assert_false(compared.changes[2].metadata_changed)
}

///|
test "permissions links and type transitions remain distinct from payload changes" {
  let a = snapshot([
    @archive.TarEntry::file("mode", b"same"),
    @archive.TarEntry::symlink("link", "mode"),
    @archive.TarEntry::file("type", b"data"),
  ])
  let b = snapshot([
    @archive.TarEntry::file("mode", b"same", mode=0o755),
    @archive.TarEntry::symlink("link", "type"),
    @archive.TarEntry::directory("type"),
  ])
  let compared = @review.compare_files(
    a.layout,
    a.report.manifest,
    b.layout,
    b.report.manifest,
  )
  assert_eq(compared.modified, 3)
  assert_true(compared.changes[0].link_changed)
  assert_true(compared.changes[1].metadata_changed)
  assert_false(compared.changes[1].content_changed)
  assert_true(compared.changes[2].type_changed)
}

///|
test "recompression is provenance change without a filesystem change" {
  let entries = [@archive.TarEntry::file("data", b"same")]
  let a = snapshot(entries)
  let b = snapshot(entries, compression=@model.Gzip)
  assert_eq(
    @review.compare_files(
      a.layout,
      a.report.manifest,
      b.layout,
      b.report.manifest,
    ).changes.length(),
    0,
  )
  let compared = @review.compare_files(
    a.layout,
    a.report.manifest,
    b.layout,
    b.report.manifest,
    include_provenance=true,
  )
  assert_eq(compared.provenance_only, 1)
  assert_eq(compared.modified, 0)
}
