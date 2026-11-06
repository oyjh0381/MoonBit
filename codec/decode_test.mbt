///|
test "manifest codec round trips the supported OCI model" {
  let digest = fixture_digest('d')
  let config : @model.Descriptor = {
    media_type: @model.media_type_config,
    digest,
    size: 123L,
    annotations: [],
    platform: None,
  }
  let layer : @model.Descriptor = {
    media_type: @model.media_type_layer_tar,
    digest: fixture_digest('e'),
    size: 456L,
    annotations: [],
    platform: None,
  }
  let manifest : @model.ImageManifest = {
    schema_version: 2,
    media_type: @model.media_type_manifest,
    config,
    layers: [layer],
    annotations: [{ key: "org.example", value: "value", }],
  }
  let decoded = @codec.decode_manifest(@codec.encode_manifest(manifest)) catch {
    error => abort(error.message())
  }
  assert_eq(decoded, manifest)
}

///|
test "index codec round trips descriptor platform and reference" {
  let descriptor : @model.Descriptor = {
    media_type: @model.media_type_manifest,
    digest: fixture_digest('f'),
    size: 88L,
    annotations: [{ key: @model.annotation_ref_name, value: "latest", }],
    platform: Some(@model.default_platform()),
  }
  let index : @model.ImageIndex = {
    schema_version: 2,
    media_type: @model.media_type_index,
    manifests: [descriptor],
    annotations: [],
  }
  let decoded = @codec.decode_index(@codec.encode_index(index)) catch {
    error => abort(error.message())
  }
  assert_eq(decoded, index)
}

///|
test "configuration codec round trips supported runtime fields" {
  let config : @model.ImageConfig = {
    created: Some("2026-01-01T00:00:00Z"),
    author: Some("MoonOCI"),
    platform: @model.default_platform(),
    runtime: {
      user: Some("1000:1000"),
      env: [{ key: "A", value: "one=two", }],
      entrypoint: ["/app"],
      cmd: ["run"],
      working_dir: "/work",
      labels: [{ key: "name", value: "demo", }],
      exposed_ports: ["8080/tcp"],
      volumes: ["/data"],
      stop_signal: Some("SIGTERM"),
    },
    diff_ids: [fixture_digest('1')],
    history: [
      {
        created: Some("2026-01-01T00:00:00Z"),
        created_by: Some("moonoci"),
        author: None,
        comment: None,
        empty_layer: false,
      },
    ],
  }
  assert_eq(@codec.decode_config(@codec.encode_config(config)), config)
}

///|
test "JSON decoder rejects excessive document size" {
  let oversized = Bytes::from_array(Array::make(16 * 1024 * 1024 + 1, b' '))
  let mut raised = false
  ignore(@codec.decode_index(oversized)) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "JSON decoder enforces nesting depth without counting strings" {
  let mut deeply_nested = ""
  for _ in 0..<129 {
    deeply_nested += "["
  }
  for _ in 0..<129 {
    deeply_nested += "]"
  }
  let mut raised = false
  ignore(@codec.decode_index(@utf8.encode(deeply_nested))) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "layout marker tolerates formatting and extension fields" {
  @codec.validate_layout_marker(
    b"{ \"extension\": true, \"imageLayoutVersion\" : \"1.0.0\" }",
  )
}
