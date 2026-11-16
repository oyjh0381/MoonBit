///|
test "pinned external tar is retained and applied between generated layers" {
  let base : @builder.LayerBuildRequest = {
    entries: [@archive.TarEntry::file("obsolete", b"old")],
    remove: [],
    opaque_dirs: [],
    compression: @model.Uncompressed,
  }
  let external = @archive.write_tar([
      @archive.TarEntry::whiteout("obsolete"),
      @archive.TarEntry::file("tool", b"outside"),
    ]) +
    Bytes::make(512, b'\x00')
  let import_pin = @digest.sha256(external)
  let layers : Array[@builder.LayerInput] = [
    Generated(base),
    PinnedTar(external, import_pin, @model.Gzip),
  ]
  let result = @builder.build_image_from_layers(
    layers,
    @model.default_platform(),
    @model.default_runtime_config(),
    "test",
  )
  assert_true(@builder.verify_memory(result.layout).is_valid())
  assert_eq(result.rootfs.map(entry => entry.path), ["tool"])
  let blob = result.report.layers[1]
  assert_eq(
    @builder.decode_layer_blob(
      blob.media_type,
      result.layout.require_blob(blob),
    ),
    external,
  )
  let config = @codec.decode_config(
    result.layout.require_blob(result.report.config),
  )
  assert_eq(config.diff_ids[1], import_pin)
  let rejected = try {
    ignore(
      @builder.build_image_from_layers(
        [PinnedTar(external, @digest.sha256(b"other"), @model.Uncompressed)],
        @model.default_platform(),
        @model.default_runtime_config(),
        "test",
      ),
    )
    false
  } catch {
    @model.DigestMismatch(_) => true
    _ => false
  }
  assert_true(rejected)
}

///|
test "adopting an existing gzip layer retains its compressed digest and DiffID" {
  let request = @builder.default_single_layer_request([
    @archive.TarEntry::file("payload", b"hello"),
  ])
  let source = @builder.build_single_layer({
    ..request,
    compression: @model.Gzip,
  })
  let descriptor = source.report.layers[0]
  let gzip = source.layout.require_blob(descriptor)
  let diff_id = @codec.decode_config(
      source.layout.require_blob(source.report.config),
    ).diff_ids[0]
  let image = @builder.build_image_from_layers(
    [PinnedGzip(gzip, descriptor.digest, diff_id)],
    request.platform,
    request.runtime,
    request.reference,
  )
  assert_eq(image.report.layers, source.report.layers)
  assert_eq(image.layout.index(), source.layout.index())
  assert_eq(image.layout.require_blob(descriptor), gzip)
  let mismatch = @digest.sha256(b"wrong")
  let first : @builder.LayerInput = PinnedGzip(gzip, mismatch, diff_id)
  let second : @builder.LayerInput = PinnedGzip(
    gzip,
    descriptor.digest,
    mismatch,
  )
  for layer in [first, second] {
    let rejected = try {
      ignore(
        @builder.build_image_from_layers(
          [layer],
          request.platform,
          request.runtime,
          request.reference,
        ),
      )
      false
    } catch {
      @model.DigestMismatch(_) => true
      _ => false
    }
    assert_true(rejected)
  }
}
