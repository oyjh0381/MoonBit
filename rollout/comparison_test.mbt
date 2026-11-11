///|
fn rollout_fixture(
  platform : @model.Platform,
  data : Bytes,
) -> @builder.BuildResult raise @model.MoonOciError {
  @builder.build_single_layer({
    ..@builder.default_single_layer_request([
      @archive.TarEntry::file("app", data),
    ]),
    platform,
  })
}

///|
test "two pinned releases distinguish updated and removed required platforms" {
  let amd64 = @model.default_platform()
  let arm64 = { ..amd64, architecture: "arm64", variant: Some("v8"), }
  let base = rollout_fixture(amd64, b"old")
  let added = rollout_fixture(arm64, b"arm")
  for blob in added.layout.blob_records() {
    ignore(base.layout.put_blob(blob.descriptor().media_type, blob.data()))
  }
  let base_root = @codec.decode_index(base.layout.index())
  base.layout.set_index(
    @codec.encode_index({
      ..base_root,
      manifests: base_root.manifests + [added.report.manifest],
    }),
  )
  let next = rollout_fixture(amd64, b"new")
  let base_pin = @digest.sha256(base.layout.index())
  let next_pin = @digest.sha256(next.layout.index())
  let result = @rollout.compare_releases(
    base.layout,
    base_pin,
    next.layout,
    next_pin,
    [arm64, amd64],
  )
  assert_eq(result.baseline_index, base_pin)
  assert_eq(result.candidate_index, next_pin)
  assert_true(result.platforms[0].transition is @rollout.Removed)
  assert_true(result.platforms[1].transition is @rollout.Updated)
  let reverse = @rollout.compare_releases(
    next.layout,
    next_pin,
    base.layout,
    base_pin,
    [arm64],
  )
  assert_true(reverse.platforms[0].transition is @rollout.Introduced)
  let same = @rollout.compare_releases(
    next.layout,
    next_pin,
    next.layout,
    next_pin,
    [amd64, arm64],
  )
  assert_true(same.platforms[0].transition is @rollout.Unchanged)
  assert_true(same.platforms[1].transition is @rollout.Unavailable)
}
