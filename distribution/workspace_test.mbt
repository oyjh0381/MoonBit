///|
fn image(
  arch : String,
  data : Bytes,
) -> @layout.MemoryLayout raise @model.MoonOciError {
  @builder.build_image({
    layers: [
      {
        entries: [@archive.TarEntry::file("app/data", data)],
        remove: [],
        opaque_dirs: [],
        compression: @model.Uncompressed,
      },
    ],
    platform: { ..@model.default_platform(), architecture: arch, },
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "demo",
    annotations: [],
  }).layout
}

///|
test "multi platform distribution is deterministic and selection yields a standalone verified graph" {
  let amd = image("amd64", b"hello")
  let arm = image("arm64", b"hello")
  let merged = @distribution.merge([amd, arm])
  assert_eq(merged.index(), @distribution.merge([arm, amd]).index())
  assert_eq(@codec.decode_index(merged.index()).manifests.length(), 2)
  let selected = @distribution.slice(merged, @model.default_platform())
  assert_true(@builder.verify_memory(selected).is_valid())
  assert_eq(selected.index(), amd.index())
  assert_true(merged.blob_count() < amd.blob_count() + arm.blob_count())
}

///|
test "ambiguous composition and unavailable platform are refused" {
  let amd = image("amd64", b"hello")
  let duplicate = try {
    ignore(@distribution.merge([amd, amd]))
    false
  } catch {
    _ => true
  }
  assert_true(duplicate)
  let absent = try {
    ignore(
      @distribution.select(amd, {
        ..@model.default_platform(),
        architecture: "arm64",
      }),
    )
    false
  } catch {
    _ => true
  }
  assert_true(absent)
}

///|
test "offline delta deduplicates shared content and refuses corrupt base" {
  let amd = image("amd64", b"hello")
  assert_eq(@distribution.missing_blobs(amd, amd).length(), 0)
  let arm = image("arm64", b"hello")
  assert_eq(@distribution.missing_blobs(amd, arm).length(), 2)
  let broken = @layout.MemoryLayout::from_untrusted_parts(
    amd.marker(),
    amd.index(),
    [],
  )
  let rejected = try {
    ignore(@distribution.missing_blobs(broken, arm))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "external pin detects a changed index even when the new graph is valid" {
  let amd = image("amd64", b"hello")
  @distribution.verify_pin(amd, @digest.sha256(amd.index()))
  let arm = image("arm64", b"hello")
  let rejected = try {
    @distribution.verify_pin(arm, @digest.sha256(amd.index()))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "forged platform metadata cannot redirect platform selection" {
  let amd = image("amd64", b"hello")
  let index = @codec.decode_index(amd.index())
  let arm = { ..@model.default_platform(), architecture: "arm64", }
  amd.set_index(
    @codec.encode_index({
      ..index,
      manifests: [{ ..index.manifests[0], platform: Some(arm), }],
    }),
  )
  let rejected = try {
    ignore(@distribution.select(amd, arm))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
