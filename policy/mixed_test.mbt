///|
test "mixed release policy checks every nested image while retaining valid attachments" {
  let ready = release({
    ..@model.default_runtime_config(),
    user: Some("65532"),
    cmd: ["/run"],
  })
  let root = @codec.decode_index(ready.index())
  let root_user = release({
    ..@model.default_runtime_config(),
    user: Some("0"),
    cmd: ["/run"],
  })
  let attached = @artifacts.attach(
    ready,
    root.manifests[0],
    "application/spdx+json",
    [],
  )
  let original = attached.layout.index()
  let accepted = @policy.evaluate_mixed(attached.layout)
  assert_true(accepted.allowed)
  assert_eq(accepted.store.artifacts_checked, 1)
  assert_eq(accepted.images.manifests_checked, 1)
  assert_eq(attached.layout.index(), original)
  let outer = @layout.MemoryLayout::new()
  for part in [attached.layout, root_user] {
    for record in part.blob_records() {
      ignore(outer.put_blob(record.descriptor().media_type, record.data()))
    }
  }
  let nested = outer.put_blob(@model.media_type_index, attached.layout.index())
  let rejected = @codec.decode_index(root_user.index()).manifests[0]
  outer.set_index(
    @codec.encode_index({ ..root, manifests: [nested, rejected], }),
  )
  let decision = @policy.evaluate_mixed(outer)
  assert_false(decision.allowed)
  assert_true(decision.store.valid)
  assert_eq(decision.images.manifests_checked, 2)
  assert_true(
    decision.images.findings.any(item => item.code == "nonroot-user-required"),
  )
  assert_true(@policy.mixed_release_json(decision).contains("source_index"))
}

///|
test "unknown branches and an artifact-only store cannot pass mixed image admission" {
  let artifact = @artifacts.build("application/json", [])
  let decision = @policy.evaluate_mixed(artifact.layout)
  assert_false(decision.allowed)
  assert_true(decision.store.valid)
  assert_true(
    decision.images.findings.any(item => item.code == "empty-distribution"),
  )
  let ready = release({
    ..@model.default_runtime_config(),
    user: Some("65532"),
    cmd: ["/run"],
  })
  let index = @codec.decode_index(ready.index())
  let unknown = ready.put_blob("application/vnd.unknown", b"opaque branch")
  ready.set_index(
    @codec.encode_index({ ..index, manifests: index.manifests + [unknown], }),
  )
  let decision = @policy.evaluate_mixed(ready)
  assert_false(decision.allowed)
  assert_false(decision.store.complete)
}
