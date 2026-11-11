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
  let mounted = plan.with_mount_source("team/base")
  assert_eq(mounted.mount_source(), Some("team/base"))
  assert_true(plan.pin() != mounted.pin())
  assert_true(mounted.pin() != plan.with_mount_source("team/cache").pin())
  assert_eq(mounted.preflight().max_requests, plan.preflight().max_requests)
  assert_eq(mounted.preflight().body_bytes, plan.preflight().body_bytes)
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

///|
test "preflight counts each planned body and the worst-case request schedule" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"budget"),
    ]),
  )
  let catalog = @lifecycle.catalog(
    image.layout,
    @digest.sha256(image.layout.index()),
  )
  let plan = @registry.plan_publication(
    catalog,
    "latest",
    @registry.RegistryOrigin::parse("https://registry.example"),
    "team/image",
    "release",
  )
  let estimate = plan.preflight()
  assert_eq(estimate.max_requests, 10)
  assert_eq(estimate.body_bytes, image.layout.blob_bytes())
  let defaults = @registry.PublishLimits::default()
  for
    limits in [
      { ..defaults, max_requests: 9, },
      { ..defaults, max_object_bytes: estimate.largest_object - 1L, },
      { ..defaults, max_total_bytes: estimate.body_bytes - 1L, },
    ] {
    let rejected = try {
      ignore(plan.preflight(limits~))
      false
    } catch {
      @model.ResourceLimitExceeded(_) => true
      _ => false
    }
    assert_true(rejected)
  }
  assert_eq(
    plan.preflight(limits={
      max_requests: estimate.max_requests,
      max_object_bytes: estimate.largest_object,
      max_total_bytes: estimate.body_bytes,
    }).body_bytes,
    estimate.body_bytes,
  )
}
