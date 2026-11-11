///|
test "read independently described Wasm manifest without artifactType" {
  let data = b"\x00asm\x01\x00\x00\x00"
  let layout = @layout.MemoryLayout::new()
  let layer = layout.put_blob("application/wasm", data)
  let config = layout.put_blob(
    "application/vnd.wasm.config.v0+json",
    @utf8.encode(
      "{\"architecture\":\"wasm\",\"os\":\"wasip1\",\"layerDigests\":[\"" +
      layer.digest.to_string() +
      "\"]}",
    ),
  )
  let manifest : @model.ImageManifest = {
    schema_version: 2,
    media_type: @model.media_type_manifest,
    config,
    layers: [layer],
    annotations: [],
  }
  let descriptor = layout.put_blob(
    @model.media_type_manifest,
    @codec.encode_manifest(manifest),
  )
  let observation = @wasmartifact.inspect(layout, descriptor)
  assert_eq(observation.data, data)
  assert_true(observation.binary.kind is @wasmartifact.CoreModule)
  assert_eq(observation.layer, layer)
  let misleading = { ..descriptor, platform: Some(@model.default_platform()), }
  let refused = try {
    ignore(@wasmartifact.inspect(layout, misleading))
    false
  } catch {
    @model.InvalidOci(_) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "reject internally consistent hashes that misstate the Wasm payload digest" {
  let layout = @layout.MemoryLayout::new()
  let layer = layout.put_blob("application/wasm", b"\x00asm\x01\x00\x00\x00")
  let config = layout.put_blob(
    "application/vnd.wasm.config.v0+json", b"{\"architecture\":\"wasm\",\"os\":\"wasip1\",\"layerDigests\":[\"sha256:0000000000000000000000000000000000000000000000000000000000000000\"]}",
  )
  let manifest : @model.ImageManifest = {
    schema_version: 2,
    media_type: @model.media_type_manifest,
    config,
    layers: [layer],
    annotations: [],
  }
  let wrong_pin = layout.put_blob(
    @model.media_type_manifest,
    @codec.encode_manifest(manifest),
  )
  let multiple = layout.put_blob(
    @model.media_type_manifest,
    @codec.encode_manifest({ ..manifest, layers: [layer, layer], }),
  )
  let mismatch = try {
    ignore(@wasmartifact.inspect(layout, wrong_pin))
    false
  } catch {
    @model.DigestMismatch(_) => true
    _ => false
  }
  assert_true(mismatch)
  let unsupported = try {
    ignore(@wasmartifact.inspect(layout, multiple))
    false
  } catch {
    @model.Unsupported(_) => true
    _ => false
  }
  assert_true(unsupported)
}
