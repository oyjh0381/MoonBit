///|
async fn rebase_command(args : Array[String], apply : Bool) -> Unit {
  if apply {
    if args.length() != 10 && args.length() != 11 {
      raise @model.InvalidArgument(
        "usage: moonoci rebase APP OLD_BASE NEW_BASE APP_PIN OLD_PIN NEW_PIN REF OUTPUT [NEW_BASE_NAME]",
      )
    }
    if @fs.exists(args[9]) {
      raise @model.IoFailure("rebased layout destination already exists")
    }
  } else {
    require_arity(
      args, 8, "usage: moonoci rebase-plan APP OLD_BASE NEW_BASE APP_PIN OLD_PIN NEW_PIN",
    )
  }
  let pins : @rebase.RebasePins = {
    application: @model.Digest::parse(args[5]),
    previous_base: @model.Digest::parse(args[6]),
    replacement_base: @model.Digest::parse(args[7]),
  }
  let app = @native.load_bounded_layout(args[2])
  let old = @native.load_bounded_layout(args[3])
  let replacement = @native.load_bounded_layout(args[4])
  if apply {
    let name = if args.length() == 11 { Some(args[10]) } else { None }
    let result = @rebase.rebase_image(
      app,
      old,
      replacement,
      pins,
      args[8],
      replacement_name?=name,
    )
    @native.write_layout(args[9], result.layout)
    @stdio.stdout.write(@rebase.result_json(result) + "\n")
  } else {
    let plan = @rebase.plan_rebase(app, old, replacement, pins)
    @stdio.stdout.write(@rebase.plan_json(plan) + "\n")
  }
}
