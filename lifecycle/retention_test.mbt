///|
test "image retention keeps linked attachments by default and drops only orphan bytes" {
  let bundle = sample_store()
  let root = @codec.decode_index(bundle.layout.index())
  let image = root.manifests[0]
  let unused = bundle.layout.put_blob("application/octet-stream", b"orphan")
  let catalog = @lifecycle.catalog(
    bundle.layout,
    @digest.sha256(bundle.layout.index()),
  )
  let plan = catalog.retain([image.digest])
  assert_eq(plan.discarded_blobs(), 1)
  assert_eq(plan.reclaimable_bytes(), unused.size)
  let result = plan.materialize()
  assert_eq(result.index(), bundle.layout.index())
  assert_true(@artifacts.verify_store(result).valid)
  assert_eq(@artifacts.referrers(result, image.digest).referrers.length(), 1)
  assert_eq(bundle.layout.blob_count(), plan.kept_blobs() + 1)
  let detached = result.blob_records()
  detached.clear()
  assert_eq(plan.materialize().blob_count(), plan.kept_blobs())
}

///|
test "artifact-only closure keeps weak subject external unless explicitly requested" {
  let bundle = sample_store()
  let catalog = @lifecycle.catalog(
    bundle.layout,
    @digest.sha256(bundle.layout.index()),
  )
  let artifact = catalog.retain([bundle.descriptor.digest]).materialize()
  assert_false(@artifacts.inspect(artifact, bundle.descriptor).subject_present)
  let complete = catalog
    .retain([bundle.descriptor.digest], policy={
      include_referrers: true,
      include_subjects: true,
    })
    .materialize()
  assert_true(
    @artifacts.inspect(complete, bundle.descriptor, require_subject=true).subject_present,
  )
  assert_true(@artifacts.verify_store(complete).valid)
  let external = @artifacts.export_artifact(bundle.layout, bundle.descriptor)
  let external_catalog = @lifecycle.catalog(
    external,
    @digest.sha256(external.index()),
  )
  let failed = try {
    ignore(
      external_catalog.retain([bundle.descriptor.digest], policy={
        include_referrers: true,
        include_subjects: true,
      }),
    )
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "retention rejects duplicate unknown and empty roots without mutating source" {
  let bundle = sample_store()
  let original = bundle.layout.index()
  let catalog = @lifecycle.catalog(bundle.layout, @digest.sha256(original))
  for
    roots in [
      [],
      [bundle.descriptor.digest, bundle.descriptor.digest],
      [@digest.sha256(b"unknown")],
    ] {
    let failed = try {
      ignore(catalog.retain(roots))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }
  assert_eq(bundle.layout.index(), original)
}
