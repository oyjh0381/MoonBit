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
async fn fail_with(code : String, message : String, status : Int32) -> Unit {
  @stdio.stderr.write(code + ": " + message + "\n")
  process_exit(status)
}
