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
