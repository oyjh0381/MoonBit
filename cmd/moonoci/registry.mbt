///|
priv struct ReferrerLockInput {
  path : String
  pin : @model.Digest
  exact_listing : Bool
}

///|
priv struct RegistryArguments {
  options : @remote.RegistryOptions
  cache_path : String?
  buffered : Bool
  artifact_type : String?
  selection : @registry.ReferrerSelection?
  referrer_lock : ReferrerLockInput?
  discovery_limits : @registry.DiscoveryLimits
  requirements : Array[@policy.ArtifactRequirement]
  release_policy_path : String?
  statement : @remote.StatementRequirement?
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
  let mut attachment_pins = None
  let mut lock_path = None
  let mut lock_pin = None
  let mut exact_referrers = false
  let mut discovery_limits = @registry.DiscoveryLimits::default()
  let requirements : Array[@policy.ArtifactRequirement] = []
  let mut release_policy_path = None
  let mut statement_pin = None
  let mut predicate_type = None
  let mut index = start
  while index < args.length() {
    match args[index] {
      "--allow-http" => options = { ..options, allow_http: true, }
      "--buffered" if output_options => buffered = true
      "--exact-referrers" if discovery && output_options => {
        if exact_referrers {
          raise @model.InvalidArgument("duplicate exact referrer option")
        }
        exact_referrers = true
      }
      "--cache"
      | "--ca-file"
      | "--proxy-origin"
      | "--allow-realm"
      | "--allow-blob-origin"
      | "--timeout-ms"
      | "--retries"
      | "--max-retry-delay-ms"
      | "--artifact-type"
      | "--attachment-pins"
      | "--referrer-lock"
      | "--referrer-lock-pin"
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
      | "--statement-digest"
      | "--statement-predicate"
      | "--release-policy"
      | "--total-timeout-ms" as flag => {
        if [
            "--require-artifact", "--release-policy", "--statement-digest", "--statement-predicate",
          ].contains(flag) &&
          !admission {
          raise @model.InvalidArgument(
            "required artifacts are only accepted by registry-admit",
          )
        }
        if ["--attachment-pins", "--referrer-lock", "--referrer-lock-pin"].contains(
            flag,
          ) &&
          (!discovery || !output_options) {
          raise @model.InvalidArgument(
            "attachment selection requires registry-bundle or registry-admit",
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
          "--statement-digest" => {
            if statement_pin is Some(_) {
              raise @model.InvalidArgument("duplicate Statement digest")
            }
            statement_pin = Some(@model.Digest::parse(args[index]))
          }
          "--statement-predicate" => {
            if predicate_type is Some(_) {
              raise @model.InvalidArgument("duplicate Statement predicate type")
            }
            @artifacts.validate_statement_predicate_type(args[index])
            predicate_type = Some(args[index])
          }
          "--proxy-origin" => {
            if options.proxy_origin is Some(_) {
              raise @model.InvalidArgument("duplicate registry proxy origin")
            }
            options = { ..options, proxy_origin: Some(args[index]), }
          }
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
          "--referrer-lock" => {
            if lock_path is Some(_) {
              raise @model.InvalidArgument("duplicate referrer lock path")
            }
            lock_path = Some(args[index])
          }
          "--referrer-lock-pin" => {
            if lock_pin is Some(_) {
              raise @model.InvalidArgument("duplicate referrer lock pin")
            }
            lock_pin = Some(@model.Digest::parse(args[index]))
          }
          "--attachment-pins" => {
            if attachment_pins is Some(_) {
              raise @model.InvalidArgument("duplicate attachment pin option")
            }
            attachment_pins = Some(parse_attachment_pins(args[index]))
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
  let referrer_lock : ReferrerLockInput? = match (lock_path, lock_pin) {
    (None, None) => None
    (Some(path), Some(pin)) =>
      Some({ path, pin, exact_listing: exact_referrers, })
    _ =>
      raise @model.InvalidArgument(
        "referrer lock path and pin must be supplied together",
      )
  }
  if referrer_lock is Some(_) && attachment_pins is Some(_) {
    raise @model.InvalidArgument(
      "choose either a referrer lock or inline attachment pins",
    )
  }
  if artifact_type is Some(_) &&
    (referrer_lock is Some(_) || attachment_pins is Some(_)) {
    raise @model.InvalidArgument(
      "attachment selection cannot use an artifact type filter",
    )
  }
  if exact_referrers && referrer_lock is None && attachment_pins is None {
    raise @model.InvalidArgument(
      "--exact-referrers requires an approved attachment selection",
    )
  }
  let selection = attachment_pins.map(pins => {
    @registry.ReferrerSelection::new(pins, exact_listing=exact_referrers)
  })
  let statement : @remote.StatementRequirement? = match
    (statement_pin, predicate_type) {
    (None, None) => None
    (Some(attachment), Some(predicate_type)) =>
      Some({ attachment, predicate_type, })
    _ =>
      raise @model.InvalidArgument(
        "Statement digest and predicate type must be supplied together",
      )
  }
  {
    options,
    cache_path,
    buffered,
    artifact_type,
    selection,
    referrer_lock,
    discovery_limits,
    requirements,
    release_policy_path,
    statement,
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
  let selection = match parsed.referrer_lock {
    None => parsed.selection
    Some(input) => {
      let lock = @native.load_referrer_lock(input.path, input.pin)
      if lock.root() != expected || lock.subject() != subject {
        raise @model.DigestMismatch(
          "referrer lock root or subject differs from the requested release",
        )
      }
      Some(lock.selection(exact_listing=input.exact_listing))
    }
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
      statement?=parsed.statement,
      selection?,
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
    selection?,
    options=parsed.options,
    discovery_limits=parsed.discovery_limits,
    cache?,
    bearer_token?,
  )
  @native.write_layout(args[7], result.layout, buffered=parsed.buffered)
  @stdio.stdout.write(result.statistics + "\n")
}
