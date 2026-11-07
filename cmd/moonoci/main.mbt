///|
extern "C" fn process_exit(code : Int32) = "exit"

///|
async fn main {
  let args = @env.args()
  try {
    if args.length() < 2 {
      print_usage()
      process_exit(2)
      return
    }
    match args[1] {
      "registry-pull" => registry_pull_command(args)
      "registry-referrers" => registry_referrers_command(args)
      "registry-bundle" => registry_bundle_command(args)
      "registry-admit" => registry_bundle_command(args, admission=true)
      "content-catalog" => {
        require_arity(
          args, 4, "usage: moonoci content-catalog INPUT EXPECTED_INDEX_PIN",
        )
        let expected = @model.Digest::parse(args[3])
        let catalog = @lifecycle.catalog(
          @native.load_bounded_layout(args[2]),
          expected,
        )
        @stdio.stdout.write(@lifecycle.catalog_json(catalog) + "\n")
      }
      "retain-plan" => {
        if args.length() < 6 {
          raise @model.InvalidArgument(
            "usage: moonoci retain-plan INPUT EXPECTED_INDEX_PIN MODE ROOT [ROOT...]",
          )
        }
        let catalog = @lifecycle.catalog(
          @native.load_bounded_layout(args[2]),
          @model.Digest::parse(args[3]),
        )
        let roots = args[5:]
          .to_owned()
          .map(value => @model.Digest::parse(value))
        let plan = catalog.retain(roots, policy=retention_policy(args[4]))
        @stdio.stdout.write(@lifecycle.retention_json(plan) + "\n")
      }
      "retain-export" | "retain-export-buffered" => {
        if args.length() < 8 {
          raise @model.InvalidArgument(
            "usage: moonoci retain-export INPUT EXPECTED_INDEX_PIN PLAN_PIN MODE OUTPUT ROOT [ROOT...]",
          )
        }
        let roots = args[7:]
          .to_owned()
          .map(value => @model.Digest::parse(value))
        let plan = @native.export_retained_layout(
          args[2],
          @model.Digest::parse(args[3]),
          roots,
          @model.Digest::parse(args[4]),
          args[6],
          policy=retention_policy(args[5]),
          buffered=args[1] == "retain-export-buffered",
        )
        @stdio.stdout.write(@lifecycle.retention_json(plan) + "\n")
      }
      "transfer-batch" => {
        require_arity(
          args, 6, "usage: moonoci transfer-batch SESSION EXPECTED_PIN MAX_CHUNKS MAX_BYTES",
        )
        let session = @native.TransferSession::open(
          args[2],
          @model.Digest::parse(args[3]),
        )
        let max_bytes = @string.parse_int64(args[5]) catch {
          _ =>
            raise @model.InvalidArgument("batch byte budget must be an integer")
        }
        let batch = session.batch(integer_argument(args[4]), max_bytes)
        @stdio.stdout.write(@transfer.batch_json(session.plan(), batch) + "\n")
      }
      "transfer-recover-chunk" => {
        require_arity(
          args, 5, "usage: moonoci transfer-recover-chunk SESSION EXPECTED_PIN INDEX",
        )
        let result = @native.recover_transfer_chunk(
          args[2],
          @model.Digest::parse(args[3]),
          integer_argument(args[4]),
        )
        @stdio.stdout.write(result + "\n")
      }
      "transfer-recover-output" => {
        require_arity(
          args, 5, "usage: moonoci transfer-recover-output SESSION EXPECTED_PIN OUTPUT_FILE",
        )
        @native.recover_transfer_output(
          args[2],
          @model.Digest::parse(args[3]),
          args[4],
        )
      }
      "chunk-plan" => {
        require_arity(
          args, 5, "usage: moonoci chunk-plan SOURCE CHUNK_BYTES OUTPUT_PLAN",
        )
        let chunk_bytes = integer_argument(args[3])
        let plan = @native.create_chunk_plan(args[2], chunk_bytes, args[4])
        @stdio.stdout.write(plan.digest().to_string() + "\n")
      }
      "chunk-export" => {
        require_arity(
          args, 7, "usage: moonoci chunk-export SOURCE PLAN EXPECTED_PIN INDEX OUTPUT_CHUNK",
        )
        @native.export_transfer_chunk(
          args[2],
          args[3],
          @model.Digest::parse(args[4]),
          integer_argument(args[5]),
          args[6],
        )
      }
      "transfer-start" => {
        require_arity(
          args, 5, "usage: moonoci transfer-start PLAN EXPECTED_PIN SESSION",
        )
        @native.start_transfer(args[2], @model.Digest::parse(args[3]), args[4])
      }
      "transfer-put" => {
        require_arity(
          args, 6, "usage: moonoci transfer-put SESSION EXPECTED_PIN INDEX CHUNK_FILE",
        )
        @native.receive_transfer_chunk(
          args[2],
          @model.Digest::parse(args[3]),
          integer_argument(args[4]),
          args[5],
        )
      }
      "transfer-status" => {
        require_arity(
          args, 4, "usage: moonoci transfer-status SESSION EXPECTED_PIN",
        )
        let progress = @native.transfer_progress(
          args[2],
          @model.Digest::parse(args[3]),
        )
        @stdio.stdout.write(@native.transfer_progress_json(progress) + "\n")
      }
      "transfer-finish" => {
        require_arity(
          args, 5, "usage: moonoci transfer-finish SESSION EXPECTED_PIN OUTPUT_FILE",
        )
        @native.finish_transfer(args[2], @model.Digest::parse(args[3]), args[4])
      }
      "artifact-gate" => {
        if args.length() < 5 {
          raise @model.InvalidArgument(
            "usage: moonoci artifact-gate INPUT SUBJECT_DIGEST REQUIRED_TYPE [REQUIRED_TYPE...]",
          )
        }
        let requirements : Array[@policy.ArtifactRequirement] = []
        for i in 4..<args.length() {
          requirements.push({
            artifact_type: args[i],
            minimum: 1,
            maximum: 128,
          })
        }
        let decision = @policy.evaluate_artifact_requirements(
          @native.load_layout(args[2]),
          @model.Digest::parse(args[3]),
          requirements,
        )
        @stdio.stdout.write(@policy.artifact_requirements_json(decision) + "\n")
        if !decision.allowed {
          process_exit(5)
        }
      }
      "artifact-attach" => {
        require_arity(
          args, 9, "usage: moonoci artifact-attach INPUT SUBJECT_DIGEST ARTIFACT_TYPE PAYLOAD_MEDIA FILE REF OUTPUT",
        )
        let descriptor = @native.attach_artifact_file(
          args[2],
          @model.Digest::parse(args[3]),
          args[4],
          args[5],
          args[6],
          args[7],
          args[8],
        )
        @stdio.stdout.write(descriptor.digest.to_string() + "\n")
      }
      "artifact-inspect" => {
        require_arity(
          args, 4, "usage: moonoci artifact-inspect INPUT ARTIFACT_DIGEST",
        )
        let store = @native.load_layout(args[2])
        let descriptor = @artifacts.resolve_subject(
          store,
          @model.Digest::parse(args[3]),
        )
        @stdio.stdout.write(
          @artifacts.observation_json(@artifacts.inspect(store, descriptor)) +
          "\n",
        )
      }
      "artifact-export" => {
        require_arity(
          args, 5, "usage: moonoci artifact-export INPUT ARTIFACT_DIGEST OUTPUT",
        )
        let store = @native.load_layout(args[2])
        let descriptor = @artifacts.resolve_subject(
          store,
          @model.Digest::parse(args[3]),
        )
        @native.write_layout(
          args[4],
          @artifacts.export_artifact(store, descriptor),
        )
      }
      "artifact-payload" => {
        require_arity(
          args, 6, "usage: moonoci artifact-payload INPUT ARTIFACT_DIGEST INDEX OUTPUT",
        )
        let index = @string.parse_int(args[4]) catch {
          _ => raise @model.InvalidArgument("payload index must be an integer")
        }
        @native.export_artifact_payload(
          args[2],
          @model.Digest::parse(args[3]),
          index,
          args[5],
        )
      }
      "referrers" => {
        if args.length() != 4 && args.length() != 5 {
          raise @model.InvalidArgument(
            "usage: moonoci referrers INPUT SUBJECT_DIGEST [ARTIFACT_TYPE]",
          )
        }
        let store = @native.load_layout(args[2])
        let subject = @model.Digest::parse(args[3])
        let report = if args.length() == 5 {
          @artifacts.referrers(store, subject, artifact_type=args[4])
        } else {
          @artifacts.referrers(store, subject)
        }
        @stdio.stdout.write(@artifacts.referrers_json(report) + "\n")
        if !report.complete {
          @stdio.stderr.write(
            "referrer discovery incomplete: unsupported descriptors present\n",
          )
          process_exit(4)
        }
      }
      "verify-store" => {
        require_arity(args, 3, "usage: moonoci verify-store INPUT")
        let report = @artifacts.verify_store(@native.load_layout(args[2]))
        @stdio.stdout.write(@artifacts.verification_json(report) + "\n")
        if !report.valid {
          process_exit(5)
        }
      }
      "flatten-pinned" => {
        if args.length() != 5 &&
          !(args.length() == 6 && args[5] == "--images-only") {
          raise @model.InvalidArgument(
            "usage: moonoci flatten-pinned INPUT EXPECTED_ROOT_PIN OUTPUT [--images-only]",
          )
        }
        let projected = @graph.project_pinned(
          @native.load_layout(args[2]),
          @model.Digest::parse(args[3]),
          allow_skipped=args.length() == 6,
        )
        @native.write_layout(args[4], projected.layout)
        @stdio.stdout.write(@graph.receipt_json(projected.receipt) + "\n")
      }
      "tree" => {
        require_arity(args, 3, "usage: moonoci tree INPUT")
        @stdio.stdout.write(
          @graph.render_json(@graph.walk_indexes(@native.load_layout(args[2]))) +
          "\n",
        )
      }
      "flatten" => {
        if args.length() != 4 &&
          !(args.length() == 5 && args[4] == "--images-only") {
          raise @model.InvalidArgument(
            "usage: moonoci flatten INPUT OUTPUT [--images-only]",
          )
        }
        @native.write_layout(
          args[3],
          @graph.flatten_images(
            @native.load_layout(args[2]),
            allow_skipped=args.length() == 5,
          ),
        )
      }
      "tree-select" => {
        require_arity(
          args, 6, "usage: moonoci tree-select INPUT OUTPUT OS ARCH",
        )
        @native.write_layout(
          args[3],
          @graph.select_image(@native.load_layout(args[2]), {
            os: args[4],
            architecture: args[5],
            variant: None,
            os_version: None,
          }),
        )
      }
      "files" => {
        require_arity(args, 5, "usage: moonoci files INPUT OS ARCH")
        let source = @native.load_layout(args[2])
        let descriptor = @distribution.select(source, {
          os: args[3],
          architecture: args[4],
          variant: None,
          os_version: None,
        })
        @stdio.stdout.write(
          @review.inventory_json(
            @builder.inventory_from_manifest(source, descriptor),
          ) +
          "\n",
        )
      }
      "diff" | "config-diff" | "upgrade-check" => {
        if args[1] == "upgrade-check" {
          require_arity(
            args, 8, "usage: moonoci upgrade-check BASE TARGET OS ARCH BASE_PIN TARGET_PIN",
          )
        } else {
          require_arity(
            args, 6, "usage: moonoci diff|config-diff BASE TARGET OS ARCH",
          )
        }
        let base = @native.load_layout(args[2])
        let target = @native.load_layout(args[3])
        let platform : @model.Platform = {
          os: args[4],
          architecture: args[5],
          variant: None,
          os_version: None,
        }
        let old = @distribution.select(base, platform)
        let next = @distribution.select(target, platform)
        match args[1] {
          "diff" =>
            @stdio.stdout.write(
              @review.files_json(@review.compare_files(base, old, target, next)) +
              "\n",
            )
          "config-diff" => {
            let a = @codec.decode_manifest(base.require_blob(old))
            let b = @codec.decode_manifest(target.require_blob(next))
            let comparison = @review.compare_configuration(
              @codec.decode_config(base.require_blob(a.config)),
              @codec.decode_config(target.require_blob(b.config)),
            )
            @stdio.stdout.write(@review.configuration_json(comparison) + "\n")
          }
          _ => {
            let approval : @review.UpgradeApproval = {
              expected_base: @model.Digest::parse(args[6]),
              expected_target: @model.Digest::parse(args[7]),
              approved_paths: [],
              approved_fields: [],
              allow_additions: false,
            }
            let decision = @review.evaluate_upgrade(
              base, old, target, next, approval,
            )
            @stdio.stdout.write(@review.upgrade_json(decision) + "\n")
            if !decision.allowed {
              process_exit(5)
            }
          }
        }
      }
      "gate" => {
        require_arity(args, 3, "usage: moonoci gate INPUT")
        let decision = @policy.evaluate(@native.load_layout(args[2]))
        @stdio.stdout.write(@policy.render_json(decision) + "\n")
        if !decision.allowed {
          process_exit(5)
        }
      }
      "delta-pack" => {
        require_arity(args, 5, "usage: moonoci delta-pack BASE TARGET ARCHIVE")
        @native.create_delta_file(args[2], args[3], args[4])
      }
      "delta-apply" => {
        require_arity(
          args, 6, "usage: moonoci delta-apply BASE ARCHIVE EXPECTED_INDEX_DIGEST OUTPUT",
        )
        @native.apply_delta_file(
          args[2],
          args[3],
          @model.Digest::parse(args[4]),
          args[5],
        )
      }
      "compact" => {
        require_arity(args, 4, "usage: moonoci compact INPUT OUTPUT")
        @native.write_layout(
          args[3],
          @distribution.compact(@native.load_layout(args[2])),
        )
      }
      "storage" => {
        require_arity(args, 3, "usage: moonoci storage INPUT")
        let stats = @distribution.storage_inventory(
          @native.load_layout(args[2]),
        )
        let output : Json = {
          "stored_blobs": Json::number(stats.stored_blobs.to_double()),
          "reachable_blobs": Json::number(stats.reachable_blobs.to_double()),
          "stored_bytes": Json::string(stats.stored_bytes.to_string()),
          "reachable_bytes": Json::string(stats.reachable_bytes.to_string()),
          "reclaimable_bytes": Json::string(stats.reclaimable_bytes.to_string()),
        }
        @stdio.stdout.write(output.stringify() + "\n")
      }
      "merge" => {
        if args.length() < 5 {
          raise @model.InvalidArgument(
            "usage: moonoci merge OUTPUT INPUT INPUT [INPUT...]",
          )
        }
        let sources = []
        for i in 3..<args.length() {
          sources.push(@native.load_layout(args[i]))
        }
        @native.write_layout(args[2], @distribution.merge(sources))
      }
      "select" => {
        require_arity(args, 6, "usage: moonoci select INPUT OUTPUT OS ARCH")
        let chosen = @distribution.slice(@native.load_layout(args[2]), {
          os: args[4],
          architecture: args[5],
          variant: None,
          os_version: None,
        })
        @native.write_layout(args[3], chosen)
      }
      "delta" => {
        require_arity(args, 4, "usage: moonoci delta BASE TARGET")
        let missing = @distribution.missing_blobs(
          @native.load_layout(args[2]),
          @native.load_layout(args[3]),
        )
        for item in missing {
          @stdio.stdout.write(
            item.digest.to_string() + "\t" + item.size.to_string() + "\n",
          )
        }
      }
      "build" => {
        if args.length() != 3 {
          raise @model.InvalidArgument("usage: moonoci build <spec.json>")
        }
        let result = @native.build_from_file(args[2])
        @stdio.stdout.write(
          "built \{result.report.manifest.digest.to_string()} with \{result.report.layers.length()} layer(s)\n",
        )
      }
      "inspect" => {
        require_arity(args, 3, "usage: moonoci inspect <layout>")
        let layout = @native.load_layout(args[2])
        let index = @codec.decode_index(layout.index())
        @stdio.stdout.write(
          "schemaVersion: \{index.schema_version}\nmanifests: \{index.manifests.length()}\n",
        )
        for descriptor in index.manifests {
          let mut reference = "<none>"
          for annotation in descriptor.annotations {
            if annotation.key == @model.annotation_ref_name {
              reference = annotation.value
            }
          }
          @stdio.stdout.write(
            "- \{descriptor.digest.to_string()} ref=\{reference} size=\{descriptor.size}\n",
          )
        }
      }
      "list" => {
        require_arity(args, 3, "usage: moonoci list <layout>")
        let layout = @native.load_layout(args[2])
        for entry in @builder.rootfs_from_layout(layout) {
          @stdio.stdout.write(
            "\{entry.kind}\t\{entry.mode.to_string(radix=8)}\t\{entry.size}\t\{entry.path}\tlayer=\{entry.layer_index}\n",
          )
        }
      }
      "verify" => {
        require_arity(args, 3, "usage: moonoci verify <layout>")
        let report = @builder.verify_memory(@native.load_layout(args[2]))
        for finding in report.findings {
          let path = match finding.object_path {
            Some(value) => " [" + value + "]"
            None => ""
          }
          @stdio.stderr.write(
            finding.code + path + ": " + finding.message + "\n",
          )
        }
        if report.is_valid() {
          @stdio.stdout.write(
            "valid: manifests=\{report.manifests_checked} blobs=\{report.blobs_checked} layers=\{report.layers_checked}\n",
          )
        } else {
          process_exit(5)
        }
      }
      "archive" => {
        require_arity(args, 4, "usage: moonoci archive <layout> <output.tar>")
        @native.archive_layout_file(args[2], args[3])
        @stdio.stdout.write("wrote " + args[3] + "\n")
      }
      "version" | "--version" | "-V" =>
        @stdio.stdout.write("moonoci 0.2.0 (unreleased)\n")
      "help" | "--help" | "-h" => print_usage()
      command => raise @model.InvalidArgument("unknown command: " + command)
    }
  } catch {
    @model.InvalidArgument(message) => fail_with("MOONOCI_ARGUMENT", message, 2)
    @model.InvalidBuildSpec(message) =>
      fail_with("MOONOCI_BUILD_SPEC", message, 2)
    @model.IoFailure(message) => fail_with("MOONOCI_IO", message, 3)
    @model.InvalidJson(message) => fail_with("MOONOCI_JSON", message, 4)
    @model.InvalidTar(message) => fail_with("MOONOCI_TAR", message, 4)
    @model.InvalidOci(message) => fail_with("MOONOCI_OCI", message, 4)
    @model.Unsupported(message) => fail_with("MOONOCI_UNSUPPORTED", message, 4)
    @model.InvalidDigest(message) => fail_with("MOONOCI_DIGEST", message, 5)
    @model.InvalidPath(message) => fail_with("MOONOCI_PATH", message, 5)
    @model.DigestMismatch(message) =>
      fail_with("MOONOCI_DIGEST_MISMATCH", message, 5)
    @model.SizeMismatch(message) =>
      fail_with("MOONOCI_SIZE_MISMATCH", message, 5)
    @model.ResourceLimitExceeded(message) =>
      fail_with("MOONOCI_RESOURCE_LIMIT", message, 5)
    error => fail_with("MOONOCI_INTERNAL", "\{error}", 70)
  }
}

///|
async fn print_usage() -> Unit {
  @stdio.stdout.write(
    (
      #|MoonOCI — deterministic OCI Image Layout builder and validator
      #|
      #|Usage:
      #|  moonoci registry-admit ORIGIN REPOSITORY REFERENCE EXPECTED_ROOT SUBJECT OUTPUT
      #|    --require-artifact TYPE [--require-artifact TYPE...] [TRANSPORT/PULL OPTIONS]
      #|  moonoci registry-bundle ORIGIN REPOSITORY REFERENCE EXPECTED_ROOT SUBJECT OUTPUT [OPTIONS]
      #|  moonoci registry-referrers ORIGIN REPOSITORY SUBJECT [OPTIONS]
      #|    --artifact-type TYPE --max-pages N --max-entries N (plus transport options below)
      #|  moonoci registry-pull ORIGIN REPOSITORY REFERENCE EXPECTED_ROOT OUTPUT [OPTIONS]
      #|    --allow-http --cache PATH --allow-realm ORIGIN --allow-blob-origin ORIGIN
      #|    --timeout-ms N --total-timeout-ms N --buffered
      #|    --retries N --max-retry-delay-ms N
      #|    --ca-file PEM_FILE (custom trust roots; certificate/name checks remain enabled)
      #|    --max-http-requests N --max-auth-requests N --max-redirects N
      #|    Pull/bundle: --max-content-bytes N --max-blob-bytes N --max-metadata-bytes N
      #|                 --max-objects N --max-visits N --max-depth N
      #|    Discovery/bundle: --max-page-bytes N --max-listing-bytes N
      #|    Optional Bearer input: MOONOCI_REGISTRY_TOKEN environment variable
      #|  moonoci content-catalog INPUT EXPECTED_INDEX_PIN
      #|  moonoci retain-plan INPUT EXPECTED_INDEX_PIN MODE ROOT [ROOT...]
      #|  moonoci retain-export INPUT EXPECTED_INDEX_PIN PLAN_PIN MODE OUTPUT ROOT [ROOT...]
      #|  moonoci retain-export-buffered INPUT EXPECTED_INDEX_PIN PLAN_PIN MODE OUTPUT ROOT [ROOT...]
      #|  Retention MODE: closure | referrers | complete
      #|  moonoci transfer-batch SESSION EXPECTED_PIN MAX_CHUNKS MAX_BYTES
      #|  moonoci transfer-recover-chunk SESSION EXPECTED_PIN INDEX
      #|  moonoci transfer-recover-output SESSION EXPECTED_PIN OUTPUT_FILE
      #|  moonoci chunk-plan SOURCE CHUNK_BYTES OUTPUT_PLAN
      #|  moonoci chunk-export SOURCE PLAN EXPECTED_PIN INDEX OUTPUT_CHUNK
      #|  moonoci transfer-start PLAN EXPECTED_PIN SESSION
      #|  moonoci transfer-put SESSION EXPECTED_PIN INDEX CHUNK_FILE
      #|  moonoci transfer-status SESSION EXPECTED_PIN
      #|  moonoci transfer-finish SESSION EXPECTED_PIN OUTPUT_FILE
      #|  moonoci artifact-gate INPUT SUBJECT REQUIRED_TYPE [REQUIRED_TYPE...]
      #|  moonoci artifact-attach INPUT SUBJECT TYPE PAYLOAD_MEDIA FILE REF OUTPUT
      #|  moonoci artifact-inspect INPUT DIGEST
      #|  moonoci artifact-export INPUT DIGEST OUTPUT
      #|  moonoci artifact-payload INPUT DIGEST INDEX OUTPUT
      #|  moonoci referrers INPUT SUBJECT [ARTIFACT_TYPE]
      #|  moonoci verify-store INPUT
      #|  moonoci flatten-pinned INPUT EXPECTED_ROOT_PIN OUTPUT [--images-only]
      #|  moonoci tree INPUT
      #|  moonoci flatten INPUT OUTPUT [--images-only]
      #|  moonoci tree-select INPUT OUTPUT OS ARCH
      #|  moonoci files INPUT OS ARCH
      #|  moonoci diff BASE TARGET OS ARCH
      #|  moonoci config-diff BASE TARGET OS ARCH
      #|  moonoci upgrade-check BASE TARGET OS ARCH BASE_PIN TARGET_PIN
      #|  moonoci merge OUTPUT INPUT INPUT [INPUT...]
      #|  moonoci select INPUT OUTPUT OS ARCH
      #|  moonoci delta BASE TARGET
      #|  moonoci delta-pack BASE TARGET ARCHIVE
      #|  moonoci delta-apply BASE ARCHIVE EXPECTED_INDEX_DIGEST OUTPUT
      #|  moonoci compact INPUT OUTPUT
      #|  moonoci storage INPUT
      #|  moonoci gate INPUT
      #|  moonoci build <spec.json>
      #|  moonoci inspect <layout>
      #|  moonoci list <layout>
      #|  moonoci verify <layout>
      #|  moonoci archive <layout> <output.tar>
      #|  moonoci version
      #|  moonoci help
      #|
    ),
  )
}

///|
fn require_arity(
  args : Array[String],
  expected : Int32,
  usage : String,
) -> Unit raise @model.MoonOciError {
  if args.length() != expected {
    raise @model.InvalidArgument(usage)
  }
}

///|
fn integer_argument(value : String) -> Int32 raise @model.MoonOciError {
  @string.parse_int(value) catch {
    _ => raise @model.InvalidArgument("chunk size/index must be an integer")
  }
}

///|
fn retention_policy(
  mode : String,
) -> @lifecycle.RetentionPolicy raise @model.MoonOciError {
  match mode {
    "closure" => { include_referrers: false, include_subjects: false, }
    "referrers" => @lifecycle.RetentionPolicy::default()
    "complete" => { include_referrers: true, include_subjects: true, }
    _ =>
      raise @model.InvalidArgument(
        "retention mode must be closure, referrers or complete",
      )
  }
}

///|
async fn fail_with(code : String, message : String, status : Int32) -> Unit {
  @stdio.stderr.write(code + ": " + message + "\n")
  process_exit(status)
}
