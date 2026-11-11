///|
test "pack a core module as a deterministic single-layer OCI artifact" {
  let data = b"\x00asm\x01\x00\x00\x00"
  let packed = @wasmartifact.pack(data, "latest")
  let repeated = @wasmartifact.pack(data, "latest")
  assert_eq(packed.layout, repeated.layout)
  let store = @artifacts.verify_store(packed.layout)
  assert_true(store.valid && store.complete)
  let observed = @artifacts.inspect(packed.layout, packed.descriptor)
  assert_eq(
    observed.manifest.config.media_type,
    @wasmartifact.config_media_type,
  )
  let payload = observed.manifest.payloads[0]
  assert_eq(payload.media_type, @wasmartifact.layer_media_type)
  assert_eq(packed.layout.require_blob(payload), data)
  let config = @codec.parse_json_document(
    packed.layout.require_blob(observed.manifest.config),
  )
  assert_eq(config, {
    "architecture": "wasm",
    "os": "wasip1",
    "layerDigests": [Json::string(payload.digest.to_string())],
  })
}

///|
test "require explicit metadata for components and encode its interface names" {
  let data = b"\x00asm\x0d\x00\x01\x00"
  let missing = try {
    ignore(@wasmartifact.pack(data, "component"))
    false
  } catch {
    @model.InvalidArgument(_) => true
    _ => false
  }
  assert_true(missing)
  let packed = @wasmartifact.pack(data, "component", component={
    imports: [],
    exports: ["greet"],
    target: Some("example:app/world"),
  })
  let observed = @artifacts.inspect(packed.layout, packed.descriptor)
  let config = @codec.parse_json_document(
    packed.layout.require_blob(observed.manifest.config),
  )
  assert_eq(config, {
    "architecture": "wasm",
    "os": "wasip2",
    "layerDigests": [
      Json::string(observed.manifest.payloads[0].digest.to_string()),
    ],
    "component": {
      "imports": [],
      "exports": ["greet"],
      "target": "example:app/world",
    },
  })
}
