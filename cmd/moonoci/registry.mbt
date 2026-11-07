///|
priv struct RegistryArguments {
  options : @remote.RegistryOptions
  cache_path : String?
  buffered : Bool
  artifact_type : String?
  discovery_limits : @registry.DiscoveryLimits
  requirements : Array[@policy.ArtifactRequirement]
  release_policy_path : String?
}

///|
fn parse_registry_options(
  args : Array[String],
  start : Int32,
  discovery~ : Bool = false,
  output_options~ : Bool = true,
  admission~ : Bool = false,
) -> RegistryArguments raise @model.MoonOciError {
  let mut options = @remote.RegistryOptions::default()
  let realms : Array[String] = []
  let blob_origins : Array[String] = []
  let mut cache_path = None
  let mut buffered = false
  let mut artifact_type = None
  let mut discovery_limits = @registry.DiscoveryLimits::default()
  let requirements : Array[@policy.ArtifactRequirement] = []
  let mut release_policy_path = None
  let mut index = start
  while index < args.length() {
    match args[index] {
      "--allow-http" => options = { ..options, allow_http: true, }
      "--buffered" if output_options => buffered = true
      "--cache"
      | "--ca-file"
      | "--allow-realm"
      | "--allow-blob-origin"
      | "--timeout-ms"
      | "--retries"
      | "--max-retry-delay-ms"
      | "--artifact-type"
      | "--max-pages"
      | "--max-entries"
      | "--max-page-bytes"
      | "--max-listing-bytes"
      | "--max-http-requests"
      | "--max-auth-requests"
      | "--max-redirects"
      | "--max-content-bytes"
      | "--max-blob-bytes"
      | "--max-metadata-bytes"
      | "--max-objects"
      | "--max-visits"
      | "--max-depth"
      | "--require-artifact"
      | "--release-policy"
      | "--total-timeout-ms" as flag => {
        if ["--require-artifact", "--release-policy"].contains(flag) &&
          !admission {
          raise @model.InvalidArgument(
            "required artifacts are only accepted by registry-admit",
          )
        }
        if (
            !output_options &&
            [
              "--cache", "--max-content-bytes", "--max-blob-bytes", "--max-metadata-bytes",
              "--max-objects", "--max-visits", "--max-depth",
            ].contains(flag)
          ) ||
          (
            !discovery &&
            [
              "--artifact-type", "--max-pages", "--max-entries", "--max-page-bytes",
              "--max-listing-bytes",
            ].contains(flag)
          ) {
          raise @model.InvalidArgument(
            "option is not supported by this registry command",
          )
        }
        if index + 1 == args.length() {
          raise @model.InvalidArgument("registry option requires a value")
        }
        index += 1
        match flag {
          "--release-policy" => {
            if release_policy_path is Some(_) {
              raise @model.InvalidArgument("duplicate release policy file")
            }
            release_policy_path = Some(args[index])
          }
          "--require-artifact" =>
            requirements.push({
              artifact_type: args[index],
              minimum: 1,
              maximum: 128,
            })
          "--max-page-bytes" =>
            discovery_limits = {
              ..discovery_limits,
              max_page_bytes: integer_argument(args[index]),
            }
          "--max-listing-bytes" =>
            discovery_limits = {
              ..discovery_limits,
              max_total_bytes: registry_byte_argument(args[index]),
            }
          "--max-http-requests" =>
            options = {
              ..options,
              max_http_requests: integer_argument(args[index]),
            }
          "--max-auth-requests" =>
            options = {
              ..options,
              max_auth_requests: integer_argument(args[index]),
            }
          "--max-redirects" =>
            options = {
              ..options,
              max_redirects: integer_argument(args[index]),
            }
          "--max-content-bytes" =>
            options = {
              ..options,
              pull_limits: {
                ..options.pull_limits,
                max_total_bytes: registry_byte_argument(args[index]),
              },
            }
          "--max-blob-bytes" =>
            options = {
              ..options,
              pull_limits: {
                ..options.pull_limits,
                max_blob_bytes: integer_argument(args[index]),
              },
            }
          "--max-metadata-bytes" =>
            options = {
              ..options,
              pull_limits: {
                ..options.pull_limits,
                max_metadata_bytes: integer_argument(args[index]),
              },
            }
          "--max-objects" =>
            options = {
              ..options,
              pull_limits: {
                ..options.pull_limits,
                max_objects: integer_argument(args[index]),
              },
            }
          "--max-visits" =>
            options = {
              ..options,
              pull_limits: {
                ..options.pull_limits,
                max_visits: integer_argument(args[index]),
              },
            }
          "--max-depth" =>
            options = {
              ..options,
              pull_limits: {
                ..options.pull_limits,
                max_depth: integer_argument(args[index]),
              },
            }
          "--artifact-type" => {
            if artifact_type is Some(_) {
              raise @model.InvalidArgument("duplicate artifact type filter")
            }
            @artifacts.validate_media_type(args[index])
            artifact_type = Some(args[index])
          }
          "--max-pages" =>
            discovery_limits = {
              ..discovery_limits,
              max_pages: integer_argument(args[index]),
            }
          "--max-entries" =>
            discovery_limits = {
              ..discovery_limits,
              max_entries: integer_argument(args[index]),
            }
          "--ca-file" => {
            if options.ca_file is Some(_) {
              raise @model.InvalidArgument("duplicate registry CA file option")
            }
            options = { ..options, ca_file: Some(args[index]), }
          }
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
          "--retries" =>
            options = { ..options, max_retries: integer_argument(args[index]), }
          "--max-retry-delay-ms" =>
            options = {
              ..options,
              max_retry_delay_ms: integer_argument(args[index]),
            }
          _ => abort("unreachable registry option")
        }
      }
      _ => raise @model.InvalidArgument("unknown registry option")
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
  discovery_limits.validate()
  @policy.validate_artifact_requirements(requirements)
  if admission && requirements.is_empty() {
    raise @model.InvalidArgument(
      "registry-admit requires --require-artifact TYPE",
    )
  }
  {
    options,
    cache_path,
    buffered,
    artifact_type,
    discovery_limits,
    requirements,
    release_policy_path,
  }
}

///|
fn registry_byte_argument(value : String) -> Int64 raise @model.MoonOciError {
  if value.is_empty() || !value.to_array().all(ch => ch >= '0' && ch <= '9') {
    raise @model.InvalidArgument(
      "registry byte budget must be non-negative decimal",
    )
  }
  @string.parse_int64(value) catch {
    _ => raise @model.InvalidArgument("registry byte budget overflows Int64")
  }
}

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
  let parsed = parse_registry_options(args, 7)
  let options = parsed.options
  ignore(
    @registry.RegistryOrigin::parse(args[2], allow_http=options.allow_http),
  )
  let output_exists = @fs.exists(args[6]) ||
    @fs.exists(args[6] + ".moonoci-staging")
  if output_exists {
    raise @model.IoFailure(
      "registry output or staging destination already exists",
    )
  }
  let cache = match parsed.cache_path {
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
  @native.write_layout(args[6], result.layout, buffered=parsed.buffered)
  @stdio.stdout.write(result.statistics + "\n")
}

///|
async fn registry_referrers_command(args : Array[String]) -> Unit {
  if args.length() < 5 {
    raise @model.InvalidArgument(
      "usage: moonoci registry-referrers ORIGIN REPOSITORY SUBJECT [OPTIONS]",
    )
  }
  let subject = @model.Digest::parse(args[4])
  let parsed = parse_registry_options(
    args,
    5,
    discovery=true,
    output_options=false,
  )
  let bearer_token = @env.get_env_var("MOONOCI_REGISTRY_TOKEN")
  let result = @remote.discover_referrers(
    args[2],
    args[3],
    subject,
    artifact_type?=parsed.artifact_type,
    options=parsed.options,
    limits=parsed.discovery_limits,
    bearer_token?,
  )
  @stdio.stdout.write(result.statistics + "\n")
}

///|
async fn registry_bundle_command(
  args : Array[String],
  admission~ : Bool = false,
) -> Unit {
  if args.length() < 8 {
    raise @model.InvalidArgument(
      "usage: moonoci registry-bundle ORIGIN REPOSITORY REFERENCE EXPECTED_ROOT SUBJECT OUTPUT [OPTIONS]",
    )
  }
  let expected = @model.Digest::parse(args[5])
  let subject = @model.Digest::parse(args[6])
  @registry.validate_repository(args[3])
  @registry.validate_reference(args[4])
  let parsed = parse_registry_options(args, 8, discovery=true, admission~)
  if admission && parsed.artifact_type is Some(_) {
    raise @model.InvalidArgument(
      "registry-admit discovers all types; artifact filter is not accepted",
    )
  }
  let release_policy = match parsed.release_policy_path {
    None => None
    Some(path) => Some(@native.load_release_policy(path))
  }
  if @fs.exists(args[7]) || @fs.exists(args[7] + ".moonoci-staging") {
    raise @model.IoFailure(
      "registry bundle output or staging destination already exists",
    )
  }
  let cache = match parsed.cache_path {
    None => None
    Some(path) => Some(@native.load_bounded_layout(path))
  }
  let bearer_token = @env.get_env_var("MOONOCI_REGISTRY_TOKEN")
  if admission {
    let result = @remote.admit_registry_release(
      args[2],
      args[3],
      args[4],
      expected,
      subject,
      parsed.requirements,
      release_policy?,
      options=parsed.options,
      discovery_limits=parsed.discovery_limits,
      cache?,
      bearer_token?,
    )
    match result.layout {
      Some(layout) =>
        @native.write_layout(args[7], layout, buffered=parsed.buffered)
      None => {
        @stdio.stdout.write(result.statistics + "\n")
        process_exit(5)
      }
    }
    @stdio.stdout.write(result.statistics + "\n")
    return
  }
  let result = @remote.pull_with_referrers(
    args[2],
    args[3],
    args[4],
    expected,
    subject,
    artifact_type?=parsed.artifact_type,
    options=parsed.options,
    discovery_limits=parsed.discovery_limits,
    cache?,
    bearer_token?,
  )
  @native.write_layout(args[7], result.layout, buffered=parsed.buffered)
  @stdio.stdout.write(result.statistics + "\n")
}
