///|
async fn registry_plan_command(args : Array[String]) -> Unit {
  let allow_http = args.length() == 9 && args[8] == "--allow-http"
  if args.length() != 8 && !allow_http {
    raise @model.InvalidArgument(
      "usage: moonoci registry-plan INPUT EXPECTED_INDEX_PIN REF ORIGIN REPOSITORY TAG [--allow-http]",
    )
  }
  let expected = @model.Digest::parse(args[3])
  let origin = @registry.RegistryOrigin::parse(args[5], allow_http~)
  let layout = @native.load_bounded_layout(args[2])
  let catalog = @lifecycle.catalog(layout, expected)
  let plan = @registry.plan_publication(
    catalog,
    args[4],
    origin,
    args[6],
    args[7],
  )
  @stdio.stdout.write(@registry.publication_json(plan) + "\n")
}
