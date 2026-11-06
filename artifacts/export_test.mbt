///|
test "artifact export keeps its payload graph and weak subject without copying the image" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("data", b"large subject"),
    ]),
  )
  let bundle = @artifacts.attach(
    image.layout,
    image.report.manifest,
    "application/json",
    [
      {
        media_type: "application/json",
        data: b"{\"sbom\":true}",
        annotations: [
          {
            key: "org.opencontainers.image.title",
            value: "../../untrusted.json",
          },
        ],
      },
    ],
  )
  let exported = @artifacts.export_artifact(bundle.layout, bundle.descriptor)
  assert_true(exported.blob_count() < bundle.layout.blob_count())
  assert_eq(
    @artifacts.payload_bytes(exported, bundle.descriptor, 0),
    b"{\"sbom\":true}",
  )
  let observed = @artifacts.inspect(exported, bundle.descriptor)
  assert_false(observed.subject_present)
  assert_eq(observed.manifest.subject, Some(image.report.manifest))
  assert_true(
    @artifacts.observation_json(observed).contains("moonoci.artifact.v1"),
  )
  for index in [-1, 1] {
    let bad = try {
      ignore(@artifacts.payload_bytes(exported, bundle.descriptor, index))
      false
    } catch {
      _ => true
    }
    assert_true(bad)
  }
}
