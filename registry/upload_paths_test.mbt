///|
test "finish the original blob upload and preserve its opaque state" {
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  let digest = @digest.sha256(b"fixture")
  let prefix = @registry.blob_upload_path("team/image")
  let location = prefix + "session-123?_state=opaque%3D&part=0"
  let target = @registry.finalize_blob_upload(
    origin,
    "team/image",
    202,
    [{ key: "LOCATION", value: origin.url() + location, }],
    digest,
  )
  assert_eq(target.path(), location + "&digest=sha256%3A" + digest.encoded)
  let relative = @registry.finalize_blob_upload(
    origin,
    "team/image",
    202,
    [{ key: "location", value: prefix + "session-456", }],
    digest,
  )
  assert_eq(
    relative.path(),
    prefix + "session-456?digest=sha256%3A" + digest.encoded,
  )
}

///|
test "refuse upload Locations outside the pinned repository or with competing digests" {
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  let digest = @digest.sha256(b"fixture")
  let prefix = @registry.blob_upload_path("team/image")
  for
    location in [
      "https://other.example" + prefix + "session",
      "/v2/other/image/blobs/uploads/session",
      prefix + "..",
      prefix + "nested/session",
      prefix + "session?DIGEST=wrong",
      prefix + "session?%64igest=wrong",
      prefix + "session?_state=token;digest=wrong",
    ] {
    let refused = try {
      ignore(
        @registry.finalize_blob_upload(
          origin,
          "team/image",
          202,
          [{ key: "Location", value: location, }],
          digest,
        ),
      )
      false
    } catch {
      @model.InvalidOci(_) => true
      _ => false
    }
    assert_true(refused)
  }
}
