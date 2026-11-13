///|
test "Root Filesystem can be reconstructed from layout Blobs" {
  let request : @builder.ImageBuildRequest = {
    layers: [
      {
        entries: [
          @archive.TarEntry::directory("dir"),
          @archive.TarEntry::file("dir/old", b"old"),
          @archive.TarEntry::file("gone", b"gone"),
        ],
        remove: [],
        opaque_dirs: [],
        compression: @model.Compression::Uncompressed,
      },
      {
        entries: [@archive.TarEntry::file("dir/new", b"new")],
        remove: ["gone"],
        opaque_dirs: ["dir"],
        compression: @model.Compression::Gzip,
      },
    ],
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "rootfs",
    annotations: [],
  }
  let result = @builder.build_image(request)
  assert_eq(@builder.rootfs_from_layout(result.layout), result.rootfs)
}

///|
fn layout_from_layer_entries(
  entries : Array[@archive.TarEntry],
) -> @layout.MemoryLayout raise @model.MoonOciError {
  let layout = @layout.MemoryLayout::new()
  let layer_tar = @archive.write_tar(entries)
  let layer = layout.put_blob(@model.media_type_layer_tar, layer_tar)
  let config : @model.ImageConfig = {
    created: None,
    author: None,
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    diff_ids: [@digest.sha256(layer_tar)],
    history: [],
  }
  let config_descriptor = layout.put_blob(
    @model.media_type_config,
    @codec.encode_config(config),
  )
  let manifest : @model.ImageManifest = {
    schema_version: 2,
    media_type: @model.media_type_manifest,
    config: config_descriptor,
    layers: [layer],
    annotations: [],
  }
  let manifest_descriptor = layout.put_blob(
    @model.media_type_manifest,
    @codec.encode_manifest(manifest),
  )
  layout.set_index(
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests: [manifest_descriptor],
      annotations: [],
    }),
  )
  layout
}

///|
test "archived whiteout does not hide its same-layer replacement" {
  let layout = layout_from_layer_entries([
    @archive.TarEntry::whiteout("same"),
    @archive.TarEntry::file("same", b"value"),
  ])
  let entries = @builder.rootfs_from_layout(layout)
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].path, "same")
  assert_eq(entries[0].size, 5L)
  assert_true(@builder.verify_memory(layout).is_valid())
}

///|
test "Root Filesystem rejects non-empty Whiteout markers" {
  let layout = layout_from_layer_entries([
    @archive.TarEntry::file(".wh.removed", b"not-empty"),
  ])
  let report = @builder.verify_memory(layout)
  assert_false(report.is_valid())
  assert_eq(report.findings.length(), 1)
  assert_true(report.findings[0].object_path.unwrap().has_suffix(".layers[0]"))
  let raised = try {
    ignore(@builder.rootfs_from_layout(layout))
    false
  } catch {
    @model.InvalidOci(_) => true
    _ => false
  }
  assert_true(raised)
}

///|
test "a valid layer digest cannot mask an invalid parent entry" {
  let layout = layout_from_layer_entries([
    @archive.TarEntry::file("parent", b"file"),
    @archive.TarEntry::file("parent/child", b"child"),
  ])
  let report = @builder.verify_memory(layout)
  assert_false(report.is_valid())
  assert_eq(report.layers_checked, 1)
  assert_eq(report.manifests_checked, 0)
}
