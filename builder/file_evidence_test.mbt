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

///|
test "image build, verification and inventory agree on a hardlink chain" {
  let file = @archive.TarEntry::file("last", b"same", mode=0o640)
  let direct = @archive.TarEntry::hardlink("first", file.path)
  let chain = @archive.TarEntry::hardlink("second", direct.path)
  let request = @builder.default_single_layer_request([chain, direct, file])
  let image = @builder.build_single_layer({
    ..request,
    compression: @model.Gzip,
  })
  assert_true(@builder.verify_memory(image.layout).is_valid())
  let observed = @builder.inventory_from_manifest(
    image.layout,
    image.report.manifest,
  )
  assert_eq(observed.map(item => item.entry.kind), [
    "hardlink", "file", "hardlink",
  ])
  for item in observed {
    assert_eq(item.content_digest, Some(@digest.sha256(b"same")))
    assert_eq(item.entry.size, 4L)
    assert_eq(item.entry.mode, 0o640)
  }
}
