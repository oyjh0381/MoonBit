///|
test "local referrers discover exact subjects and forward artifact type plus manifest annotations" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("data", b"image"),
    ]),
  )
  let sbom = @artifacts.attach(
    image.layout,
    image.report.manifest,
    "application/spdx+json",
    [],
    annotations=[{ key: "example.format", value: "spdx", }],
  )
  let provenance = @artifacts.attach(
    sbom.layout,
    image.report.manifest,
    "application/vnd.in-toto+json",
    [],
  )
  let all = @artifacts.referrers(
    provenance.layout,
    image.report.manifest.digest,
  )
  assert_true(all.complete)
  assert_eq(all.referrers.length(), 2)
  let filtered = @artifacts.referrers(
    provenance.layout,
    image.report.manifest.digest,
    artifact_type="application/spdx+json",
  )
  assert_eq(filtered.referrers.length(), 1)
  assert_eq(filtered.referrers[0].descriptor.annotations, [
    { key: "example.format", value: "spdx", },
  ])
  let json = @artifacts.referrers_json(filtered)
  assert_true(json.contains("\"artifactType\":\"application/spdx+json\""))
  assert_true(json.contains("example.format"))
  assert_eq(
    @artifacts.referrers(provenance.layout, provenance.descriptor.digest).referrers.length(),
    0,
  )
}

///|
test "repeated references produce one referrer and unknown media keep discovery incomplete" {
  let artifact = @artifacts.build("application/json", [])
  let attached = @artifacts.attach(
    artifact.layout,
    artifact.descriptor,
    "application/json",
    [],
  )
  let index = @codec.decode_index(attached.layout.index())
  let unknown = {
    ..attached.descriptor,
    media_type: "application/example.unknown",
    digest: @model.Digest::sha256("0".repeat(64)),
  }
  attached.layout.set_index(
    @codec.encode_index({
      ..index,
      manifests: index.manifests + [attached.descriptor, unknown],
    }),
  )
  let report = @artifacts.referrers(attached.layout, artifact.descriptor.digest)
  assert_eq(report.referrers.length(), 1)
  assert_false(report.complete)
  assert_eq(report.unrecognized.length(), 1)
}
