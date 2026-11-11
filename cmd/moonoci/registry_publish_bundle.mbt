///|
async fn registry_bundle_publish_command(
  args : Array[String],
  apply : Bool,
) -> Unit {
  let start = if apply { 10 } else { 9 }
  if args.length() < start {
    raise @model.InvalidArgument(
      "usage: moonoci registry-{plan,publish}-bundle INPUT INDEX_PIN REF ORIGIN REPO TAG ATTACHMENT_PINS [BUNDLE_PIN] [--allow-http] [--ca-file FILE]",
    )
  }
  let options = parse_publish_options(args, start)
  let expected = if apply { Some(@model.Digest::parse(args[9])) } else { None }
  let pins = parse_attachment_pins(args[8])
  let index_pin = @model.Digest::parse(args[3])
  let origin = @registry.RegistryOrigin::parse(
    args[5],
    allow_http=options.allow_http,
  )
  let source = @native.load_bounded_layout(args[2])
  let bundle = @registry.plan_bundle_publication(
    @lifecycle.catalog(source, index_pin),
    args[4],
    origin,
    args[6],
    args[7],
    pins,
  )
  match expected {
    None =>
      @stdio.stdout.write(@registry.bundle_publication_json(bundle) + "\n")
    Some(pin) => {
      let bearer_token = @env.get_env_var("MOONOCI_REGISTRY_PUSH_TOKEN")
      let receipt = @remote.publish_registry_bundle(
        bundle,
        pin,
        options~,
        bearer_token?,
      )
      @stdio.stdout.write(@remote.bundle_receipt_json(receipt) + "\n")
    }
  }
}

///|
fn parse_attachment_pins(
  value : String,
) -> Array[@model.Digest] raise @model.MoonOciError {
  if value.length() > 128 * 72 {
    raise @model.InvalidArgument("attachment digest list exceeds 128 entries")
  }
  let pins : Array[@model.Digest] = []
  for item in value.split(",") {
    if pins.length() == 128 {
      raise @model.InvalidArgument("attachment digest list exceeds 128 entries")
    }
    pins.push(@model.Digest::parse(item.to_owned()))
  }
  pins
}
