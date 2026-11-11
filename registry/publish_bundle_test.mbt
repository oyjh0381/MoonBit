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
  let discovery = @registry.DiscoveryLimits::default()
  let base_estimate = plan.publication().preflight()
  let estimate = plan.preflight(discovery~)
  assert_eq(
    estimate.max_requests,
    base_estimate.max_requests + 8 + discovery.max_pages,
  )
  let entries : Array[@artifacts.ReferrerAdvertisement] = plan
    .attachments()
    .map(item => {
      descriptor: {
        digest: item.object.digest,
        media_type: item.object.media_type,
        size: item.object.data.length().to_int64(),
        annotations: [],
        platform: None,
      },
      artifact_type: Some(item.artifact_type),
    })
  @registry.verify_bundle_advertisements(plan, entries)
  let corrupted = [
    { ..entries[0], artifact_type: Some("application/octet-stream"), },
    entries[1],
  ]
  for listing in [corrupted, [entries[0]]] {
    let rejected = try {
      @registry.verify_bundle_advertisements(plan, listing)
      false
    } catch {
      @model.InvalidOci(_) => true
      _ => false
    }
    assert_true(rejected)
  }
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
