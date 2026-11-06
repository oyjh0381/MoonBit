///|
fn pins(
  a : @builder.ImageBuildResult,
  b : @builder.ImageBuildResult,
) -> @review.UpgradeApproval {
  {
    expected_base: a.report.manifest.digest,
    expected_target: b.report.manifest.digest,
    approved_paths: [],
    approved_fields: [],
    allow_additions: false,
  }
}

///|
test "upgrade gate requires explicit approval of observed file changes" {
  let a = snapshot([@archive.TarEntry::file("app", b"old")])
  let b = snapshot([
    @archive.TarEntry::file("app", b"new"),
    @archive.TarEntry::file("new", b"extra"),
  ])
  let blocked = @review.evaluate_upgrade(
    a.layout,
    a.report.manifest,
    b.layout,
    b.report.manifest,
    pins(a, b),
  )
  assert_false(blocked.allowed)
  assert_eq(blocked.unreviewed_paths, ["app", "new"])
  let allowed = @review.evaluate_upgrade(
    a.layout,
    a.report.manifest,
    b.layout,
    b.report.manifest,
    { ..pins(a, b), approved_paths: ["app"], allow_additions: true, },
  )
  assert_true(allowed.allowed)
  assert_true(@review.upgrade_json(allowed).contains("moonoci.upgrade.v1"))
}

///|
test "approvals cannot silently carry across target versions or stale paths" {
  let a = snapshot([@archive.TarEntry::file("app", b"old")])
  let b = snapshot([@archive.TarEntry::file("app", b"new")])
  let c = snapshot([@archive.TarEntry::file("app", b"next")])
  let wrong = try {
    ignore(
      @review.evaluate_upgrade(
        a.layout,
        a.report.manifest,
        c.layout,
        c.report.manifest,
        pins(a, b),
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(wrong)
  let stale = try {
    ignore(
      @review.evaluate_upgrade(
        a.layout,
        a.report.manifest,
        b.layout,
        b.report.manifest,
        { ..pins(a, b), approved_paths: ["missing"], },
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(stale)
}

///|
test "unchanged images need no approval" {
  let image = snapshot([@archive.TarEntry::file("app", b"same")])
  assert_true(
    @review.evaluate_upgrade(
      image.layout,
      image.report.manifest,
      image.layout,
      image.report.manifest,
      pins(image, image),
    ).allowed,
  )
}
