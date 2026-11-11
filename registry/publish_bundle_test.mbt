///|
test "bundle publication verifies immediate subjects and deduplicates shared payloads" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"fixture"),
    ]),
  )
  let payload : Array[@artifacts.ArtifactPayload] = [
    { media_type: "application/json", data: b"[]", annotations: [], },
  ]
  let sbom = @artifacts.attach(
    image.layout,
    image.report.manifest,
    "application/spdx+json",
    payload,
  )
  let proof = @artifacts.attach(
    sbom.layout,
    image.report.manifest,
    "application/in-toto+json",
    payload,
  )
  let catalog = @lifecycle.catalog(
    proof.layout,
    @digest.sha256(proof.layout.index()),
  )
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  let plan = @registry.plan_bundle_publication(
    catalog,
    "latest",
    origin,
    "team/app",
    "stable",
    [sbom.descriptor.digest, proof.descriptor.digest],
  )
  let reversed = @registry.plan_bundle_publication(
    catalog,
    "latest",
    origin,
    "team/app",
    "stable",
    [proof.descriptor.digest, sbom.descriptor.digest],
  )
  assert_eq(plan.pin(), reversed.pin())
  assert_eq(plan.attachments().length(), 2)
  assert_eq(
    plan.publication().blobs().length(),
    image.report.layers.length() + 3,
  )
  assert_eq(plan.publication().root(), image.report.manifest.digest)
  let wrong = try {
    ignore(
      @registry.plan_bundle_publication(
        catalog,
        "latest",
        origin,
        "team/app",
        "stable",
        [image.report.manifest.digest],
      ),
    )
    false
  } catch {
    @model.InvalidOci(_) => true
    _ => false
  }
  assert_true(wrong)
}
