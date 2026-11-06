///|
/// An unsigned content identifier for exactly this review decision, including
/// physical source membership, output bytes, selected roots and weak-link policy.
pub fn RetentionPlan::pin(self : RetentionPlan) -> @model.Digest {
  let lines = [
    "moonoci.retention.v1",
    self.catalog.store_pin.to_string(),
    @digest.sha256(self.output_index).to_string(),
    self.policy.include_referrers.to_string(),
    self.policy.include_subjects.to_string(),
    "selected",
    self.selected.map(d => d.to_string()).join("\n"),
    "kept",
    self.kept.map(d => d.digest.to_string()).join("\n"),
    "discarded",
    self.discarded.map(d => d.digest.to_string()).join("\n"),
  ]
  @digest.sha256(@utf8.encode(lines.join("\n") + "\n"))
}

///|
/// Bind host review to a plan, then revalidate the complete current source.
/// Changed root bytes, orphan membership or content refuse the stale decision.
/// Returns a fresh copy; never applies filesystem deletions.
pub fn RetentionPlan::apply(
  self : RetentionPlan,
  current : @layout.MemoryLayout,
  expected_plan : @model.Digest,
  limits~ : CatalogLimits = CatalogLimits::default(),
) -> @layout.MemoryLayout raise @model.MoonOciError {
  ignore(@model.Digest::parse(expected_plan.to_string()))
  if self.pin() != expected_plan {
    raise @model.DigestMismatch("unexpected retention review pin")
  }
  let fresh = catalog(current, self.catalog.index_pin, limits~)
  if fresh.store_pin != self.catalog.store_pin {
    raise @model.DigestMismatch(
      "retention source physical membership changed after review",
    )
  }
  self.materialize()
}
