///|
test "multi-layer build applies whiteout and opaque semantics" {
  let request : ImageBuildRequest = {
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
  let result = build_image(request)
  assert_eq(result.report.layers.length(), 2)
  assert_true(verify_memory(result.layout).is_valid())
  assert_eq(result.rootfs.map(entry => entry.path), [
    "cache", "cache/current", "etc", "etc/new", "keep",
  ])
  assert_eq(result.rootfs[1].layer_index, 1)
}

///|
test "whiteout and opaque markers are physically present in layer tar" {
  let request : ImageBuildRequest = {
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
  let result = build_image(request)
  let entries = @archive.read_tar(
    result.layout.require_blob(result.report.layers[0]),
  )
  assert_eq(entries.map(entry => entry.path), [
    "cache/.wh..wh..opq", "etc/.wh.old",
  ])
}

///|
test "layer cannot add and remove the same path" {
  let request : ImageBuildRequest = {
    layers: [
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
  let mut raised = false
  ignore(build_image(request)) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "cannot add a child below a surviving regular file" {
  let request : ImageBuildRequest = {
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
  ignore(build_image(request)) catch {
    _ => raised = true
  }
  assert_true(raised)
}
