///|
async fn registry_plan_command(args : Array[String]) -> Unit {
  let allow_http = args.length() == 9 && args[8] == "--allow-http"
  if args.length() != 8 && !allow_http {
    raise @model.InvalidArgument(
      "usage: moonoci registry-plan INPUT EXPECTED_INDEX_PIN REF ORIGIN REPOSITORY TAG [--allow-http]",
    )
  }
  let plan = read_publication_plan(args, allow_http)
  @stdio.stdout.write(@registry.publication_json(plan) + "\n")
}

///|
async fn read_publication_plan(
  args : Array[String],
  allow_http : Bool,
) -> @registry.PublishPlan {
  let expected = @model.Digest::parse(args[3])
  let origin = @registry.RegistryOrigin::parse(args[5], allow_http~)
  let layout = @native.load_bounded_layout(args[2])
  let catalog = @lifecycle.catalog(layout, expected)
  @registry.plan_publication(catalog, args[4], origin, args[6], args[7])
}

///|
async fn registry_publish_command(args : Array[String]) -> Unit {
  if args.length() < 9 {
    raise @model.InvalidArgument(
      "usage: moonoci registry-publish INPUT EXPECTED_INDEX_PIN REF ORIGIN REPOSITORY TAG PLAN_PIN [--allow-http] [--ca-file FILE]",
    )
  }
  let review_pin = @model.Digest::parse(args[8])
  let mut options = @remote.PublishOptions::default()
  let mut index = 9
  while index < args.length() {
    match args[index] {
      "--allow-http" if !options.allow_http =>
        options = { ..options, allow_http: true, }
      "--ca-file" if options.ca_file is None && index + 1 < args.length() => {
        index += 1
        options = { ..options, ca_file: Some(args[index]), }
      }
      _ => raise @model.InvalidArgument("invalid Registry publication option")
    }
    index += 1
  }
  let plan = read_publication_plan(args, options.allow_http)
  let bearer_token = @env.get_env_var("MOONOCI_REGISTRY_PUSH_TOKEN")
  let receipt = @remote.publish_registry(
    plan,
    review_pin,
    options~,
    bearer_token?,
  )
  @stdio.stdout.write(@remote.publication_receipt_json(receipt) + "\n")
}
