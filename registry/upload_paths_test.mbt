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

///|
test "mount request encodes the source and preserves the single fallback session" {
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  let digest = @digest.sha256(b"fixture")
  let prefix = @registry.blob_upload_path("team/release")
  assert_eq(
    @registry.blob_mount_path("team/release", "team/base", digest),
    prefix + "?mount=sha256%3A" + digest.encoded + "&from=team%2Fbase",
  )
  let mount = @registry.finish_blob_mount(
    origin,
    "team/release",
    201,
    [
      {
        key: "Location",
        value: "/v2/team/release/blobs/" + digest.to_string(),
      },
    ],
    digest,
  )
  assert_true(mount is None)
  let session = @registry.finish_blob_mount(
    origin,
    "team/release",
    202,
    [{ key: "Location", value: prefix + "fallback?opaque=1", }],
    digest,
  ).unwrap()
  assert_eq(
    session.path(),
    prefix + "fallback?opaque=1&digest=sha256%3A" + digest.encoded,
  )
}

///|
test "mount refusal cannot turn a foreign session or different digest into success" {
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  let digest = @digest.sha256(b"fixture")
  let cases : Array[(Int32, Array[@model.KeyValue])] = [
    (
      202,
      [
        {
          key: "Location",
          value: "https://other.example/v2/team/release/blobs/uploads/id",
        },
      ],
    ),
    (201, []),
    (
      201,
      [
        {
          key: "Location",
          value: "/v2/team/release/blobs/" + digest.to_string(),
        },
        {
          key: "Docker-Content-Digest",
          value: @digest.sha256(b"other").to_string(),
        },
      ],
    ),
    (403, []),
  ]
  for case_ in cases {
    let (status, headers) = case_
    let refused = try {
      ignore(
        @registry.finish_blob_mount(
          origin, "team/release", status, headers, digest,
        ),
      )
      false
    } catch {
      @model.InvalidOci(_) | @model.DigestMismatch(_) | @model.IoFailure(_) =>
        true
      _ => false
    }
    assert_true(refused)
  }
}
