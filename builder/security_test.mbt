///|
test "verification rejects gzip expansion above 200 to one" {
  let fixture =
    #|H4sIAAAAAAAEAO3BMQEAAADCoPVPbQhfoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPgMc6jinAAAQAA==
  let compressed = @base64.decode(fixture)
  let mut raised = false
  ignore(decode_layer_blob(@model.media_type_layer_gzip, compressed)) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "verification rejects unsupported layer media type" {
  let mut raised = false
  ignore(decode_layer_blob("application/example", b"data")) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "layout verification rejects unknown layer media type" {
  let source = build_single_layer(
    default_single_layer_request([@archive.TarEntry::file("file", b"data")]),
  )
  let source_manifest = @codec.decode_manifest(
    source.layout.require_blob(source.report.manifest),
  )
  let target = @layout.MemoryLayout::new()
  let config = target.put_blob(
    source_manifest.config.media_type,
    source.layout.require_blob(source_manifest.config),
  )
  let unknown_layer = target.put_blob(
    "application/vnd.example.layer.v1+custom",
    source.layout.require_blob(source_manifest.layers[0]),
  )
  let manifest : @model.ImageManifest = {
    ..source_manifest,
    config,
    layers: [unknown_layer],
  }
  let manifest_descriptor = target.put_blob(
    @model.media_type_manifest,
    @codec.encode_manifest(manifest),
  )
  target.set_index(
    @codec.encode_index({
      schema_version: 2,
      media_type: @model.media_type_index,
      manifests: [manifest_descriptor],
      annotations: [],
    }),
  )
  let report = verify_memory(target)
  assert_false(report.is_valid())
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].level, @model.FindingLevel::Error)
  assert_true(report.findings[0].object_path is Some(_))
}

///|
test "layout verification rejects index document media type" {
  let image = build_single_layer(
    default_single_layer_request([@archive.TarEntry::file("file", b"data")]),
  )
  let index = @codec.decode_index(image.layout.index())
  image.layout.set_index(
    @codec.encode_index({ ..index, media_type: "application/example" }),
  )
  assert_false(verify_memory(image.layout).is_valid())
}

///|
test "layout verification rejects manifest descriptor media type" {
  let image = build_single_layer(
    default_single_layer_request([@archive.TarEntry::file("file", b"data")]),
  )
  let index = @codec.decode_index(image.layout.index())
  let descriptor = {
    ..index.manifests[0],
    media_type: @model.media_type_config,
  }
  image.layout.set_index(
    @codec.encode_index({ ..index, manifests: [descriptor] }),
  )
  assert_false(verify_memory(image.layout).is_valid())
}

///|
test "layout verification rejects manifest and config media types" {
  let wrong_manifest = build_single_layer(
    default_single_layer_request([@archive.TarEntry::file("file", b"data")]),
  )
  let wrong_manifest_index = @codec.decode_index(wrong_manifest.layout.index())
  let manifest = @codec.decode_manifest(
    wrong_manifest.layout.require_blob(wrong_manifest_index.manifests[0]),
  )
  let manifest_descriptor = wrong_manifest.layout.put_blob(
    @model.media_type_manifest,
    @codec.encode_manifest({ ..manifest, media_type: "application/example" }),
  )
  wrong_manifest.layout.set_index(
    @codec.encode_index({
      ..wrong_manifest_index,
      manifests: [manifest_descriptor],
    }),
  )
  assert_false(verify_memory(wrong_manifest.layout).is_valid())

  let wrong_config = build_single_layer(
    default_single_layer_request([@archive.TarEntry::file("file", b"data")]),
  )
  let wrong_config_index = @codec.decode_index(wrong_config.layout.index())
  let config_manifest = @codec.decode_manifest(
    wrong_config.layout.require_blob(wrong_config_index.manifests[0]),
  )
  let config_descriptor = {
    ..config_manifest.config,
    media_type: "application/example",
  }
  let config_manifest_descriptor = wrong_config.layout.put_blob(
    @model.media_type_manifest,
    @codec.encode_manifest({ ..config_manifest, config: config_descriptor }),
  )
  wrong_config.layout.set_index(
    @codec.encode_index({
      ..wrong_config_index,
      manifests: [config_manifest_descriptor],
    }),
  )
  assert_false(verify_memory(wrong_config.layout).is_valid())
}

///|
test "verification accumulates independent manifest findings with paths" {
  let image = build_single_layer(
    default_single_layer_request([@archive.TarEntry::file("file", b"data")]),
  )
  let index = @codec.decode_index(image.layout.index())
  let first = { ..index.manifests[0], media_type: @model.media_type_config }
  let second = { ..index.manifests[0], size: index.manifests[0].size + 1L }
  image.layout.set_index(
    @codec.encode_index({ ..index, manifests: [first, second] }),
  )
  let report = verify_memory(image.layout)
  assert_false(report.is_valid())
  assert_eq(report.findings.length(), 2)
  assert_eq(report.findings.map(finding => finding.object_path), [
    Some("index.manifests[0].mediaType"),
    Some("index.manifests[1]"),
  ])
  assert_eq(report.manifests_checked, 0)
  assert_eq(report.blobs_checked, 3)
  assert_eq(report.layers_checked, 1)
}
