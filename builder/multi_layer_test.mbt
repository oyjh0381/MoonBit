///|
test "multi-layer build applies whiteout and opaque semantics" {
  let request : @builder.ImageBuildRequest = {
    layers: [
      {
        entries: [
          @archive.TarEntry::directory("etc"),
          @archive.TarEntry::file("etc/old", b"old"),
          @archive.TarEntry::directory("cache"),
          @archive.TarEntry::file("cache/inherited", b"old"),
          @archive.TarEntry::file("keep", b"yes"),
        ],
        remove: [],
        opaque_dirs: [],
        compression: @model.Compression::Uncompressed,
      },
      {
        entries: [
          @archive.TarEntry::file("etc/new", b"new"),
          @archive.TarEntry::file("cache/current", b"new"),
        ],
        remove: ["/etc/old"],
        opaque_dirs: ["/cache"],
        compression: @model.Compression::Gzip,
      },
    ],
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "multi",
    annotations: [],
  }
  let result = @builder.build_image(request)
  assert_eq(result.report.layers.length(), 2)
  assert_true(@builder.verify_memory(result.layout).is_valid())
  assert_eq(result.rootfs.map(entry => entry.path), [
    "cache", "cache/current", "etc", "etc/new", "keep",
  ])
  assert_eq(result.rootfs[1].layer_index, 1)
}

///|
test "whiteout and opaque markers are physically present in layer tar" {
  let request : @builder.ImageBuildRequest = {
    layers: [
      {
        entries: [],
        remove: ["etc/old"],
        opaque_dirs: ["cache"],
        compression: @model.Compression::Uncompressed,
      },
    ],
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "markers",
    annotations: [],
  }
  let result = @builder.build_image(request)
  let entries = @archive.read_tar(
    result.layout.require_blob(result.report.layers[0]),
  )
  assert_eq(entries.map(entry => entry.path), [
    "cache/.wh..wh..opq", "etc/.wh.old",
  ])
}

///|
test "replace a lower directory with a file using an explicit whiteout" {
  let request : @builder.ImageBuildRequest = {
    layers: [
      {
        entries: [
          @archive.TarEntry::directory("same"),
          @archive.TarEntry::file("same/old", b"old"),
          @archive.TarEntry::file("kept", b"kept"),
        ],
        remove: [],
        opaque_dirs: [],
        compression: @model.Uncompressed,
      },
      {
        entries: [@archive.TarEntry::file("same", b"value")],
        remove: ["same"],
        opaque_dirs: [],
        compression: @model.Compression::Uncompressed,
      },
    ],
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "invalid",
    annotations: [],
  }
  let result = @builder.build_image(request)
  assert_eq(result.rootfs.map(entry => entry.path), ["kept", "same"])
  assert_eq(result.rootfs, @builder.rootfs_from_layout(result.layout))
}

///|
test "root opacity leaves same-layer additions visible" {
  let defaults = @builder.default_single_layer_request([])
  let result = @builder.build_image({
    layers: [
      {
        entries: [@archive.TarEntry::file("old/child", b"lower")],
        remove: [],
        opaque_dirs: [],
        compression: @model.Uncompressed,
      },
      {
        entries: [@archive.TarEntry::file("new", b"upper")],
        remove: [],
        opaque_dirs: ["/"],
        compression: @model.Uncompressed,
      },
    ],
    platform: defaults.platform,
    runtime: defaults.runtime,
    created: None,
    author: None,
    reference: "opaque-root",
    annotations: [],
  })
  assert_eq(result.rootfs.map(entry => entry.path), ["new"])
  assert_eq(result.rootfs, @builder.rootfs_from_layout(result.layout))
}

///|
test "cannot add a child below a surviving regular file" {
  let request : @builder.ImageBuildRequest = {
    layers: [
      {
        entries: [@archive.TarEntry::file("parent", b"file")],
        remove: [],
        opaque_dirs: [],
        compression: @model.Compression::Uncompressed,
      },
      {
        entries: [@archive.TarEntry::file("parent/child", b"bad")],
        remove: [],
        opaque_dirs: [],
        compression: @model.Compression::Uncompressed,
      },
    ],
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "invalid",
    annotations: [],
  }
  let mut raised = false
  ignore(@builder.build_image(request)) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "redeclared directory preserves inherited children" {
  let request : @builder.ImageBuildRequest = {
    layers: [
      {
        entries: [
          @archive.TarEntry::directory("parent"),
          @archive.TarEntry::file("parent/inherited", b"old"),
        ],
        remove: [],
        opaque_dirs: [],
        compression: @model.Compression::Uncompressed,
      },
      {
        // Deliberately reversed to prove parent-before-child application.
        entries: [
          @archive.TarEntry::file("parent/new", b"new"),
          @archive.TarEntry::directory("parent"),
        ],
        remove: [],
        opaque_dirs: [],
        compression: @model.Compression::Uncompressed,
      },
    ],
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "directory-merge",
    annotations: [],
  }
  let result = @builder.build_image(request)
  let expected = ["parent", "parent/inherited", "parent/new"]
  assert_eq(result.rootfs.map(entry => entry.path), expected)
  assert_eq(
    @builder.rootfs_from_layout(result.layout).map(entry => entry.path),
    expected,
  )
}

///|
test "reserved whiteout path cannot be supplied as an addition" {
  let request : @builder.ImageBuildRequest = {
    layers: [
      {
        entries: [@archive.TarEntry::file("etc/.wh.hidden", b"payload")],
        remove: [],
        opaque_dirs: [],
        compression: @model.Compression::Uncompressed,
      },
    ],
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "reserved-whiteout",
    annotations: [],
  }
  let mut raised = false
  ignore(@builder.build_image(request)) catch {
    _ => raised = true
  }
  assert_true(raised)
}
