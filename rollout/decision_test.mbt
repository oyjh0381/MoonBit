///|
test "rollout approval binds a changed path to its exact manifest pair" {
  let platform = @model.default_platform()
  let old = rollout_fixture(platform, b"old")
  let next = rollout_fixture(platform, b"new")
  let policy : @rollout.RolloutPolicy = {
    baseline_index: @digest.sha256(old.layout.index()),
    candidate_index: @digest.sha256(next.layout.index()),
    required: [platform],
    approvals: [],
    allow_new_platforms: false,
  }
  let rejected = @rollout.evaluate_rollout(old.layout, next.layout, policy)
  assert_false(rejected.allowed)
  assert_eq(rejected.platforms[0].upgrade.unwrap().unreviewed_paths, ["app"])
  let approval : @review.UpgradeApproval = {
    expected_base: old.report.manifest.digest,
    expected_target: next.report.manifest.digest,
    approved_paths: ["app"],
    approved_fields: [],
    allow_additions: false,
  }
  let permitted = { ..policy, approvals: [{ platform, approval, }], }
  assert_true(
    @rollout.evaluate_rollout(old.layout, next.layout, permitted).allowed,
  )
  let stale = try {
    ignore(
      @rollout.evaluate_rollout(old.layout, next.layout, {
        ..permitted,
        approvals: [
          {
            platform,
            approval: {
              ..approval,
              expected_target: old.report.manifest.digest,
            },
          },
        ],
      }),
    )
    false
  } catch {
    @model.DigestMismatch(_) => true
    _ => false
  }
  assert_true(stale)
}

///|
test "unchanged manifest identity cannot hide corrupted candidate layer bytes" {
  let platform = @model.default_platform()
  let old = rollout_fixture(platform, b"same")
  let layer = old.report.layers[0].digest
  let corrupted = @layout.MemoryLayout::from_untrusted_parts(
    old.layout.marker(),
    old.layout.index(),
    old.layout
    .blob_records()
    .map(record => {
      let descriptor = record.descriptor()
      (
        descriptor,
        if descriptor.digest == layer {
          b"broken"
        } else {
          record.data()
        },
      )
    }),
  )
  let pin = @digest.sha256(old.layout.index())
  let policy : @rollout.RolloutPolicy = {
    baseline_index: pin,
    candidate_index: pin,
    required: [platform],
    approvals: [],
    allow_new_platforms: false,
  }
  assert_true(@rollout.evaluate_rollout(old.layout, old.layout, policy).allowed)
  let rejected = try {
    ignore(@rollout.evaluate_rollout(old.layout, corrupted, policy))
    false
  } catch {
    @model.InvalidOci(_) => true
    _ => false
  }
  assert_true(rejected)
}

///|
test "complete rollout refuses an omitted exact variant on either release" {
  let amd = @model.default_platform()
  let arm = { ..amd, architecture: "arm64", variant: Some("v8"), }
  let a = rollout_fixture(amd, b"same")
  let b = rollout_fixture(arm, b"arm")
  let pin = @digest.sha256(a.layout.index())
  let index = @codec.decode_index(a.layout.index())
  let mixed = @layout.MemoryLayout::from_untrusted_parts(
    a.layout.marker(),
    @codec.encode_index({
      ..index,
      manifests: [a.report.manifest, b.report.manifest],
    }),
    (a.layout.blob_records() + b.layout.blob_records()).map(record => {
      (record.descriptor(), record.data())
    }),
  )
  let mixed_pin = @digest.sha256(mixed.index())
  let policy : @rollout.RolloutPolicy = {
    baseline_index: pin,
    candidate_index: mixed_pin,
    required: [amd],
    approvals: [],
    allow_new_platforms: false,
  }
  let scoped = @rollout.evaluate_rollout(a.layout, mixed, policy)
  assert_true(scoped.allowed)
  assert_eq(scoped.comparison.candidate_omitted, [arm])
  assert_false(
    @rollout.evaluate_rollout(a.layout, mixed, policy, complete=true).allowed,
  )
  let reversed = @rollout.evaluate_rollout(
    mixed,
    a.layout,
    { ..policy, baseline_index: mixed_pin, candidate_index: pin, },
    complete=true,
  )
  assert_false(reversed.allowed)
  assert_eq(reversed.comparison.baseline_omitted, [arm])
}
