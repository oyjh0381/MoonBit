///|
extern "C" fn process_exit(code : Int) = "exit"

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
        let index = @codec.decode_index(layout.index)
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
        for entry in @build.rootfs_from_layout(layout) {
          @stdio.stdout.write(
            "\{entry.kind}\t\{entry.mode.to_string(radix=8)}\t\{entry.size}\t\{entry.path}\tlayer=\{entry.layer_index}\n",
          )
        }
      }
      "verify" => {
        require_arity(args, 3, "usage: moonoci verify <layout>")
        let report = @build.verify_memory(@native.load_layout(args[2]))
        if report.is_valid() {
          @stdio.stdout.write(
            "valid: manifests=\{report.manifests_checked} blobs=\{report.blobs_checked} layers=\{report.layers_checked}\n",
          )
        } else {
          for finding in report.findings {
            @stdio.stderr.write(finding.code + ": " + finding.message + "\n")
          }
          process_exit(5)
        }
      }
      "archive" => {
        require_arity(args, 4, "usage: moonoci archive <layout> <output.tar>")
        @native.archive_layout_file(args[2], args[3])
        @stdio.stdout.write("wrote " + args[3] + "\n")
      }
      "version" | "--version" | "-V" => @stdio.stdout.write("moonoci 0.1.0\n")
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
  expected : Int,
  usage : String,
) -> Unit raise @model.MoonOciError {
  if args.length() != expected {
    raise @model.InvalidArgument(usage)
  }
}

///|
async fn fail_with(code : String, message : String, status : Int) -> Unit {
  @stdio.stderr.write(code + ": " + message + "\n")
  process_exit(status)
}
