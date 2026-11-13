///|
async fn registry_plan_command(args : Array[String]) -> Unit {
  if args.length() < 8 {
    raise @model.InvalidArgument(
      "usage: moonoci registry-plan INPUT EXPECTED_INDEX_PIN REF ORIGIN REPOSITORY TAG [--allow-http] [--mount-from REPOSITORY]",
    )
  }
  let (options, mount_source) = parse_publish_options(args, 8)
  let plan = read_publication_plan(args, options.allow_http, mount_source)
  @stdio.stdout.write(@registry.publication_json(plan) + "\n")
}

///|
async fn read_publication_plan(
  args : Array[String],
  allow_http : Bool,
  mount_source : String?,
) -> @registry.PublishPlan {
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
  match mount_source {
    Some(source) => plan.with_mount_source(source)
    None => plan
  }
}

///|
async fn registry_publish_command(args : Array[String]) -> Unit {
  if args.length() < 9 {
    raise @model.InvalidArgument(
      "usage: moonoci registry-publish INPUT EXPECTED_INDEX_PIN REF ORIGIN REPOSITORY TAG PLAN_PIN [--allow-http] [--ca-file FILE]",
    )
  }
  let review_pin = @model.Digest::parse(args[8])
  let (options, mount_source) = parse_publish_options(args, 9)
  let plan = read_publication_plan(args, options.allow_http, mount_source)
  let receipt = execute_publication(plan, review_pin, options)
  @stdio.stdout.write(@remote.publication_receipt_json(receipt) + "\n")
}

///|
fn parse_publish_options(
  args : Array[String],
  start : Int32,
) -> (@remote.PublishOptions, String?) raise @model.MoonOciError {
  let mut options = @remote.PublishOptions::default()
  let mut mount_source = None
  let mut index = start
  while index < args.length() {
    match args[index] {
      "--allow-http" if !options.allow_http =>
        options = { ..options, allow_http: true, }
      "--mount-from" if mount_source is None && index + 1 < args.length() => {
        index += 1
        @registry.validate_repository(args[index])
        mount_source = Some(args[index])
      }
      "--ca-file" if options.ca_file is None && index + 1 < args.length() => {
        index += 1
        options = { ..options, ca_file: Some(args[index]), }
      }
      _ => raise @model.InvalidArgument("invalid Registry publication option")
    }
    index += 1
  }
  (options, mount_source)
}

///|
async fn execute_publication(
  plan : @registry.PublishPlan,
  review_pin : @model.Digest,
  options : @remote.PublishOptions,
) -> @remote.PublicationReceipt {
  let bearer_token = @env.get_env_var("MOONOCI_REGISTRY_PUSH_TOKEN")
  @remote.publish_registry(plan, review_pin, options~, bearer_token?)
}
