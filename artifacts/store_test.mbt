///|
test "subject bound attachments preserve the source and verify exact payload bytes" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("data", b"image"),
    ]),
  )
  let count = image.layout.blob_count()
  let bundle = @artifacts.attach(
    image.layout,
    image.report.manifest,
    "application/spdx+json",
    [
      {
        media_type: "application/spdx+json",
        data: b"{\"spdxVersion\":\"SPDX-2.3\"}",
        annotations: [],
      },
    ],
  )
  assert_eq(image.layout.blob_count(), count)
  let observed = @artifacts.inspect(
    bundle.layout,
    bundle.descriptor,
    require_subject=true,
  )
  assert_true(observed.subject_present)
  assert_eq(observed.manifest.subject, Some(image.report.manifest))
  assert_eq(
    bundle.layout.require_blob(observed.manifest.payloads[0]),
    b"{\"spdxVersion\":\"SPDX-2.3\"}",
  )
}

///|
test "artifact quotas refuse oversized input without changing the source" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("data", b"image"),
    ]),
  )
  let original = image.layout.index()
  let rejected = try {
    ignore(
      @artifacts.attach(
        image.layout,
        image.report.manifest,
        "application/json",
        [
          {
            media_type: "application/json",
            data: b"too large",
            annotations: [],
          },
        ],
        limits={
          ..@artifacts.ArtifactLimits::default(),
          max_payload_bytes: 1L,
        },
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(image.layout.index(), original)
}

///|
test "standalone artifacts may carry weak subjects in separate graphs" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("data", b"image"),
    ]),
  )
  let artifact = @artifacts.build(
    "application/vnd.in-toto+json",
    [],
    subject=image.report.manifest,
  )
  assert_false(
    @artifacts.inspect(artifact.layout, artifact.descriptor).subject_present,
  )
  let unavailable = try {
    ignore(
      @artifacts.inspect(
        artifact.layout,
        artifact.descriptor,
        require_subject=true,
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(unavailable)
}
