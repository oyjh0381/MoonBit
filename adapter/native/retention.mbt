///|
/// Reconstruct a reviewed copy plan from the current bounded source, compare
/// its identity, and validate the output's supported image/artifact semantics.
/// Source files are never removed. Parent directories remain host-owned.
pub async fn export_retained_layout(
  source : String,
  expected_index : @model.Digest,
  roots : Array[@model.Digest],
  expected_plan : @model.Digest,
  destination : String,
  policy~ : @lifecycle.RetentionPolicy = @lifecycle.RetentionPolicy::default(),
  buffered~ : Bool = false,
) -> @lifecycle.RetentionPlan {
  if @fs.exists(destination) {
    raise @model.IoFailure("retained layout destination already exists")
  }
  let layout = load_bounded_layout(source)
  let catalog = @lifecycle.catalog(layout, expected_index)
  let plan = catalog.retain(roots, policy~)
  if plan.pin() != expected_plan {
    raise @model.DigestMismatch(
      "retention decision differs from the reviewed plan pin",
    )
  }
  let result = plan.materialize()
  let verified = @artifacts.verify_store(result)
  if !verified.valid || !verified.complete {
    raise @model.InvalidOci(
      "retained content fails the supported image/artifact verification profile",
    )
  }
  write_layout(destination, result, buffered~)
  plan
}
