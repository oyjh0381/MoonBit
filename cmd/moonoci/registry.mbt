///|
async fn registry_pull_command(args : Array[String]) -> Unit {
  if args.length() < 7 {
    raise @model.InvalidArgument(
      "usage: moonoci registry-pull ORIGIN REPOSITORY REFERENCE EXPECTED_ROOT OUTPUT [OPTIONS]",
    )
  }
  let expected = @model.Digest::parse(args[5])
  @registry.validate_repository(args[3])
  @registry.validate_reference(args[4])
  let mut options = @remote.RegistryOptions::default()
  let realms : Array[String] = []
  let blob_origins : Array[String] = []
  let mut cache_path = None
  let mut buffered = false
  let mut index = 7
  while index < args.length() {
    match args[index] {
      "--allow-http" => options = { ..options, allow_http: true, }
      "--buffered" => buffered = true
      "--cache"
      | "--allow-realm"
      | "--allow-blob-origin"
      | "--timeout-ms"
      | "--total-timeout-ms" as flag => {
        if index + 1 == args.length() {
          raise @model.InvalidArgument("registry option requires a value")
        }
        index += 1
        match flag {
          "--cache" => {
            if cache_path is Some(_) {
              raise @model.InvalidArgument("duplicate registry cache option")
            }
            cache_path = Some(args[index])
          }
          "--allow-realm" => realms.push(args[index])
          "--allow-blob-origin" => blob_origins.push(args[index])
          "--timeout-ms" =>
            options = {
              ..options,
              request_timeout_ms: integer_argument(args[index]),
            }
          "--total-timeout-ms" =>
            options = {
              ..options,
              total_timeout_ms: integer_argument(args[index]),
            }
          _ => abort("unreachable registry option")
        }
      }
      _ => raise @model.InvalidArgument("unknown registry-pull option")
    }
    index += 1
  }
  if realms.length() > 16 || blob_origins.length() > 16 {
    raise @model.ResourceLimitExceeded(
      "registry origin allowlist exceeds quota",
    )
  }
  let allow_http = options.allow_http
  options = {
    ..options,
    allowed_realms: realms.map(value => {
      @registry.RegistryOrigin::parse(value, allow_http~)
    }),
    allowed_blob_origins: blob_origins.map(value => {
      @registry.RegistryOrigin::parse(value, allow_http~)
    }),
  }
  options.validate()
  ignore(@registry.RegistryOrigin::parse(args[2], allow_http~))
  let output_exists = @fs.exists(args[6]) ||
    @fs.exists(args[6] + ".moonoci-staging")
  if output_exists {
    raise @model.IoFailure(
      "registry output or staging destination already exists",
    )
  }
  let cache = match cache_path {
    Some(path) => Some(@native.load_bounded_layout(path))
    None => None
  }
  let bearer_token = @env.get_env_var("MOONOCI_REGISTRY_TOKEN")
  let result = @remote.pull_registry(
    args[2],
    args[3],
    args[4],
    expected,
    options~,
    cache?,
    bearer_token?,
  )
  @native.write_layout(args[6], result.layout, buffered~)
  @stdio.stdout.write(result.statistics + "\n")
}
