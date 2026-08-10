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
test "layout verification warns for unknown layer media type" {
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
  assert_true(report.is_valid())
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].level, @model.FindingLevel::Warning)
  assert_true(report.findings[0].object_path is Some(_))
}
