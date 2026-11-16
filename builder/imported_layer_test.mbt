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
