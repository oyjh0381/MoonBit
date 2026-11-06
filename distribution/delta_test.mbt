///|
test "offline hydration shares layer content and reconstructs exact target index" {
  let base = image("amd64", b"hello")
  let target = image("arm64", b"hello")
  let envelope = @distribution.create_delta(base, target)
  assert_eq(envelope.blobs.length(), 2)
  let hydrated = @distribution.hydrate(
    base,
    envelope,
    @digest.sha256(target.index()),
  )
  assert_eq(hydrated.index(), target.index())
  assert_eq(hydrated.blob_count(), target.blob_count())
  assert_true(@builder.verify_memory(hydrated).is_valid())
  assert_eq(@distribution.create_delta(base, base).blobs.length(), 0)
}

///|
test "corrupt truncated and wrong target envelopes fail without mutating base" {
  let base = image("amd64", b"hello")
  let target = image("arm64", b"hello")
  let envelope = @distribution.create_delta(base, target)
  let pin = @digest.sha256(target.index())
  let original = base.index()
  let damaged = { ..envelope.blobs[0], data: b"forged", }
  for
    bad in [
      { ..envelope, blobs: [damaged], },
      { ..envelope, blobs: [], },
      { ..envelope, index: b"{}", },
      { ..envelope, blobs: [envelope.blobs[0], envelope.blobs[0]], },
    ] {
    let rejected = try {
      ignore(@distribution.hydrate(base, bad, pin))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
    assert_eq(base.index(), original)
  }
  let wrong_pin = try {
    ignore(@distribution.hydrate(base, envelope, @digest.sha256(original)))
    false
  } catch {
    _ => true
  }
  assert_true(wrong_pin)
}

///|
test "transfer quotas count metadata and actual bytes instead of claimed sizes" {
  let base = image("amd64", b"hello")
  let target = image("arm64", b"hello")
  let limits = {
    ..@distribution.TransferLimits::default(),
    max_total_bytes: 1L,
  }
  let rejected = try {
    ignore(@distribution.create_delta(base, target, limits~))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let invalid = try {
    ignore(
      @distribution.create_delta(base, target, limits={
        ..limits,
        max_blobs: 0,
      }),
    )
    false
  } catch {
    _ => true
  }
  assert_true(invalid)
}
