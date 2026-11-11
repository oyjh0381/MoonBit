///|
async fn wrap_release_command(args : Array[String]) -> Unit {
  require_arity(
    args, 6, "usage: moonoci wrap-release INPUT INDEX_PIN REF OUTPUT",
  )
  if @fs.exists(args[5]) {
    raise @model.IoFailure("wrapped release destination already exists")
  }
  let expected = @model.Digest::parse(args[3])
  let source = @native.load_bounded_layout(args[2])
  let wrapped = @lifecycle.catalog(source, expected).wrap_index(args[4])
  @native.write_layout(args[5], wrapped)
  let result : Json = {
    "schema": "moonoci.wrapped-release.v1",
    "root": Json::string(expected.to_string()),
    "indexDigest": Json::string(@digest.sha256(wrapped.index()).to_string()),
  }
  @stdio.stdout.write(result.stringify() + "\n")
}

///|
async fn registry_promotion_command(
  args : Array[String],
  apply : Bool,
  bundled~ : Bool = false,
) -> Unit {
  let pin_position = if bundled { 10 } else { 9 }
  let start = if apply { pin_position + 1 } else { pin_position }
  if args.length() < start {
    raise @model.InvalidArgument(
      "usage: moonoci registry-promote[-bundle][-plan] BASE CANDIDATE POLICY REF ORIGIN REPOSITORY TAG [ATTACHMENT_PINS] [PROMOTION_PIN] [--allow-http] [--ca-file FILE]",
    )
  }
  let options = parse_publish_options(args, start)
  let expected = if apply {
    Some(@model.Digest::parse(args[pin_position]))
  } else {
    None
  }
  let origin = @registry.RegistryOrigin::parse(
    args[6],
    allow_http=options.allow_http,
  )
  let policy_document = @native.read_rollout_policy_document(args[4])
  let baseline = @native.load_bounded_layout(args[2])
  let candidate = @native.load_bounded_layout(args[3])
  let review = if bundled {
    @promotion.prepare_bundle(
      baseline,
      candidate,
      policy_document,
      args[5],
      origin,
      args[7],
      args[8],
      parse_attachment_pins(args[9]),
    )
  } else {
    @promotion.prepare(
      baseline,
      candidate,
      policy_document,
      args[5],
      origin,
      args[7],
      args[8],
    )
  }
  match expected {
    Some(pin) => {
      if review.pin() != pin {
        raise @model.DigestMismatch("Registry promotion review pin mismatch")
      }
      let result : Map[String, Json] = {
        "schema": "moonoci.promotion-receipt.v1",
        "promotionPin": Json::string(pin.to_string()),
      }
      if review.bundle() is Some(bundle) {
        let bearer_token = @env.get_env_var("MOONOCI_REGISTRY_PUSH_TOKEN")
        let receipt = @remote.publish_registry_bundle(
          bundle,
          bundle.pin(),
          options~,
          bearer_token?,
        )
        result["bundle"] = @remote.bundle_receipt_value(receipt)
        result["publication"] = @remote.publication_receipt_value(
          receipt.publication,
        )
      } else {
        let plan = review.publication()
        let receipt = execute_publication(plan, plan.pin(), options)
        result["publication"] = @remote.publication_receipt_value(receipt)
      }
      @stdio.stdout.write(Json::object(result).stringify() + "\n")
    }
    None => @stdio.stdout.write(@promotion.review_json(review) + "\n")
  }
}
