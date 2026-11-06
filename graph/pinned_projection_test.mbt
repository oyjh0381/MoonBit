///|
test "pinned projection binds original and derived indexes and refuses stale pins" {
  let a = image("amd64")
  let expected = @model.Digest::sha256("0".repeat(64))
  let refused = try {
    ignore(@graph.walk_pinned(a.layout, expected))
    false
  } catch {
    _ => true
  }
  assert_true(refused)
  let tree = nest(a.layout)
  let pin = @digest.sha256(tree.index())
  let projected = @graph.project_pinned(tree, pin)
  assert_eq(projected.receipt.source_index, pin)
  assert_eq(
    projected.receipt.projected_index,
    @digest.sha256(projected.layout.index()),
  )
  assert_true(
    projected.receipt.source_index != projected.receipt.projected_index,
  )
  assert_eq(projected.receipt.image_manifests, [a.report.manifest.digest])
  assert_eq(projected.receipt.skipped_descriptors, 0)
}
