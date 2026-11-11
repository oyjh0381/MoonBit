///|
fn selection_advertisement(data : Bytes) -> @artifacts.ReferrerAdvertisement {
  {
    descriptor: {
      digest: @digest.sha256(data),
      size: data.length().to_int64(),
      media_type: @model.media_type_manifest,
      annotations: [],
      platform: None,
    },
    artifact_type: Some("application/json"),
  }
}

///|
test "referrer selection resolves only explicit pins in canonical digest order" {
  let a = selection_advertisement(b"a")
  let b = selection_advertisement(b"b")
  let extra = selection_advertisement(b"extra")
  let input = [b.descriptor.digest, a.descriptor.digest]
  let selected = @registry.ReferrerSelection::new(input)
  input.clear()
  let pins = selected.pins()
  assert_eq(pins.length(), 2)
  assert_true(pins[0].to_string() < pins[1].to_string())
  assert_eq(
    selected.resolve([b, extra, a]).map(entry => entry.descriptor.digest),
    pins,
  )
  for entries in [[b], [a, a, b]] {
    let refused = try {
      ignore(selected.resolve(entries))
      false
    } catch {
      @model.DigestMismatch(_) | @model.InvalidOci(_) => true
      _ => false
    }
    assert_true(refused)
  }
  let exact = @registry.ReferrerSelection::new(pins, exact_listing=true)
  assert_eq(exact.resolve([a, b]).length(), 2)
  let refused = try {
    ignore(exact.resolve([a, b, extra]))
    false
  } catch {
    @model.DigestMismatch(_) => true
    _ => false
  }
  assert_true(refused)
}

///|
test "referrer selection rejects empty and repeated approval lists" {
  let digest = @digest.sha256(b"a")
  for pins in [[], [digest, digest], Array::make(129, digest)] {
    let refused = try {
      ignore(@registry.ReferrerSelection::new(pins))
      false
    } catch {
      @model.InvalidArgument(_) => true
      _ => false
    }
    assert_true(refused)
  }
}
