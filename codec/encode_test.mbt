///|
fn fixture_digest(seed : Char) -> @model.Digest raise @model.MoonOciError {
  @model.Digest::parse("sha256:" + seed.to_string().repeat(64))
}

///|
test "descriptor JSON uses OCI field order and sorted annotations" {
  let descriptor : @model.Descriptor = {
    media_type: @model.media_type_layer_tar,
    digest: fixture_digest('a'),
    size: 12L,
    annotations: [{ key: "z", value: "last" }, { key: "a", value: "first" }],
    platform: None,
  }
  inspect(
    encode_descriptor(descriptor),
    content=(
      #|{"mediaType":"application/vnd.oci.image.layer.v1.tar","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":12,"annotations":{"a":"first","z":"last"}}
    ),
  )
}

///|
test "image configuration JSON is stable" {
  let config : @model.ImageConfig = {
    created: Some("2026-01-01T00:00:00Z"),
    author: None,
    platform: @model.default_platform(),
    runtime: {
      user: None,
      env: [{ key: "Z", value: "2" }, { key: "A", value: "1" }],
      entrypoint: ["/app"],
      cmd: ["serve"],
      working_dir: "/work",
      labels: [{ key: "org.example.name", value: "demo" }],
      exposed_ports: ["8080/tcp"],
      volumes: ["/data"],
      stop_signal: Some("SIGTERM"),
    },
    diff_ids: [fixture_digest('b')],
    history: [],
  }
  let first = encode_config(config)
  let second = encode_config(config)
  assert_eq(first, second)
  assert_true(first.length() > 200)
}

///|
test "duplicate deterministic map keys are rejected" {
  let descriptor : @model.Descriptor = {
    media_type: @model.media_type_layer_tar,
    digest: fixture_digest('c'),
    size: 0L,
    annotations: [{ key: "same", value: "a" }, { key: "same", value: "b" }],
    platform: None,
  }
  let mut raised = false
  ignore(encode_descriptor(descriptor)) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "duplicate runtime object-set members are rejected" {
  let base : @model.ImageConfig = {
    created: None,
    author: None,
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    diff_ids: [],
    history: [],
  }
  let mut exposed_ports_raised = false
  ignore(
    encode_config({
      ..base,
      runtime: { ..base.runtime, exposed_ports: ["8080/tcp", "8080/tcp"] },
    }),
  ) catch {
    _ => exposed_ports_raised = true
  }
  assert_true(exposed_ports_raised)
  let mut volumes_raised = false
  ignore(
    encode_config({
      ..base,
      runtime: { ..base.runtime, volumes: ["/data", "/data"] },
    }),
  ) catch {
    _ => volumes_raised = true
  }
  assert_true(volumes_raised)
}
