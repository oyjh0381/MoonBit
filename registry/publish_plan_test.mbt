///|
test "publication plan binds source membership and the exact destination" {
  let fixture = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"release"),
    ]),
  )
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  let index_pin = @digest.sha256(fixture.layout.index())
  let catalog = @lifecycle.catalog(fixture.layout, index_pin)
  let plan = @registry.plan_publication(
    catalog, "latest", origin, "team/app", "stable",
  )
  let repeated = @registry.plan_publication(
    catalog, "latest", origin, "team/app", "stable",
  )
  let moved = @registry.plan_publication(
    catalog, "latest", origin, "team/app", "candidate",
  )
  assert_eq(plan.pin(), repeated.pin())
  assert_true(plan.pin() != moved.pin())
  assert_eq(plan.root(), fixture.report.manifest.digest)
  let manifests = plan.manifests()
  assert_eq(manifests.length(), 1)
  assert_eq(@digest.sha256(manifests[0].data), plan.root())
  manifests.clear()
  assert_eq(plan.manifests().length(), 1)
  ignore(fixture.layout.put_blob("application/octet-stream", b"new orphan"))
  let refreshed = @registry.plan_publication(
    @lifecycle.catalog(fixture.layout, index_pin),
    "latest",
    origin,
    "team/app",
    "stable",
  )
  assert_true(plan.pin() != refreshed.pin())
  assert_eq(plan.blobs().length(), refreshed.blobs().length())
}
