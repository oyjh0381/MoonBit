///|
/// Explicit manifest pins for a bounded Referrers API listing.
/// Exact mode rejects other advertised digests after pagination completes.
pub struct ReferrerSelection {
  priv pins : Array[@model.Digest]
  priv exact_listing : Bool
}

///|
pub fn ReferrerSelection::new(
  pins : Array[@model.Digest],
  exact_listing~ : Bool = false,
) -> ReferrerSelection raise @model.MoonOciError {
  if pins.is_empty() || pins.length() > 128 {
    raise @model.InvalidArgument(
      "referrer selection requires 1..128 manifest digests",
    )
  }
  let ordered = pins.copy()
  ordered.sort_by((a, b) => a.to_string().compare(b.to_string()))
  for index, pin in ordered {
    ignore(@model.Digest::parse(pin.to_string()))
    if index > 0 && ordered[index - 1] == pin {
      raise @model.InvalidArgument("duplicate selected referrer digest")
    }
  }
  { pins: ordered, exact_listing, }
}

///|
pub fn ReferrerSelection::pins(
  self : ReferrerSelection,
) -> Array[@model.Digest] {
  self.pins.copy()
}

///|
pub fn ReferrerSelection::exact_listing(self : ReferrerSelection) -> Bool {
  self.exact_listing
}

///|
/// Resolve a completed, deduplicated listing in digest order. Additional
/// advertisements can either be ignored or refused before any referrer pull.
pub fn ReferrerSelection::resolve(
  self : ReferrerSelection,
  listing : Array[@artifacts.ReferrerAdvertisement],
) -> Array[@artifacts.ReferrerAdvertisement] raise @model.MoonOciError {
  let matches : Map[String, @artifacts.ReferrerAdvertisement?] = Map([])
  for pin in self.pins {
    matches[pin.to_string()] = None
  }
  for entry in listing {
    let key = entry.descriptor.digest.to_string()
    match matches.get(key) {
      Some(None) => matches[key] = Some(entry)
      Some(Some(_)) =>
        raise @model.InvalidOci("selected referrer occurs more than once")
      None =>
        if self.exact_listing {
          raise @model.DigestMismatch(
            "registry advertises an unapproved referrer: " + key,
          )
        }
    }
  }
  self.pins.map(pin => {
    let key = pin.to_string()
    guard matches.get(key) is Some(Some(entry)) else {
      raise @model.DigestMismatch("registry omits an approved referrer: " + key)
    }
    entry
  })
}
