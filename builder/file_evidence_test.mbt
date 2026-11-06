///|
test "file evidence follows overwrite whiteout and inherited layer ownership" {
  let built = @builder.build_image({
    layers: [
      {
        entries: [
          @archive.TarEntry::file("kept", b"old"),
          @archive.TarEntry::file("changed", b"one"),
          @archive.TarEntry::file("gone", b"x"),
        ],
        remove: [],
        opaque_dirs: [],
        compression: @model.Uncompressed,
      },
      {
        entries: [@archive.TarEntry::file("changed", b"two", mode=0o600)],
        remove: ["gone"],
        opaque_dirs: [],
        compression: @model.Gzip,
      },
    ],
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "test",
    annotations: [],
  })
  let inventory = @builder.inventory_from_manifest(
    built.layout,
    built.report.manifest,
  )
  assert_eq(inventory.map(f => f.entry.path), ["changed", "kept"])
  assert_eq(inventory[0].content_digest, Some(@digest.sha256(b"two")))
  assert_eq(inventory[0].entry.mode, 0o600)
  assert_eq(inventory[0].layer_digest, built.report.layers[1].digest)
  assert_eq(inventory[1].layer_digest, built.report.layers[0].digest)
  assert_eq(inventory[1].content_digest, Some(@digest.sha256(b"old")))
}

///|
test "symlink evidence never hashes or follows its target" {
  let built = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("data", b"hello"),
      @archive.TarEntry::symlink("link", "data"),
    ]),
  )
  let inventory = @builder.inventory_from_manifest(
    built.layout,
    built.report.manifest,
  )
  assert_eq(inventory[1].entry.path, "link")
  assert_eq(inventory[1].entry.link_target, Some("data"))
  assert_eq(inventory[1].content_digest, None)
}
