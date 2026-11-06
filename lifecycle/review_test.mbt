///|
test "retention review pin rejects stale physical membership even with unchanged index" {
  let bundle = sample_store()
  let index = bundle.layout.index()
  let source_pin = @digest.sha256(index)
  let catalog = @lifecycle.catalog(bundle.layout, source_pin)
  let plan = catalog.retain([bundle.descriptor.digest])
  let before = plan.apply(bundle.layout, plan.pin())
  assert_true(@artifacts.verify_store(before).valid)
  ignore(bundle.layout.put_blob("application/octet-stream", b"new orphan"))
  assert_eq(bundle.layout.index(), index)
  let stale = try {
    ignore(plan.apply(bundle.layout, plan.pin()))
    false
  } catch {
    _ => true
  }
  assert_true(stale)
  let fresh = @lifecycle.catalog(bundle.layout, source_pin).retain([
    bundle.descriptor.digest,
  ])
  assert_true(fresh.pin() != plan.pin())
  let wrong = try {
    ignore(fresh.apply(bundle.layout, plan.pin()))
    false
  } catch {
    _ => true
  }
  assert_true(wrong)
  assert_eq(plan.materialize().index(), before.index())
}

///|
test "review identity is independent of physical insertion order and input root ordering" {
  let bundle = sample_store()
  let pin = @digest.sha256(bundle.layout.index())
  let root = @codec.decode_index(bundle.layout.index())
  let records = bundle.layout
    .blob_records()
    .map(b => (b.descriptor(), b.data()))
  let reversed = []
  for i in 0..<records.length() {
    reversed.push(records[records.length() - i - 1])
  }
  let reordered = @layout.MemoryLayout::from_untrusted_parts(
    bundle.layout.marker(),
    bundle.layout.index(),
    reversed,
  )
  let first = @lifecycle.catalog(bundle.layout, pin).retain([
    root.manifests[0].digest,
    bundle.descriptor.digest,
  ])
  let second = @lifecycle.catalog(reordered, pin).retain([
    bundle.descriptor.digest,
    root.manifests[0].digest,
  ])
  assert_eq(first.pin(), second.pin())
  assert_eq(first.materialize().index(), second.materialize().index())
  let different_policy = @lifecycle.catalog(bundle.layout, pin).retain(
    [root.manifests[0].digest, bundle.descriptor.digest],
    policy={ include_referrers: false, include_subjects: false, },
  )
  assert_true(first.pin() != different_policy.pin())
}
