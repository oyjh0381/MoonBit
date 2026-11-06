///|
/// Supported layer compression methods.
pub(all) enum Compression {
  Uncompressed
  Gzip
} derive(Debug, Eq)

///|
/// Stable key/value entry used where deterministic ordering is required.
pub(all) struct KeyValue {
  key : String
  value : String
} derive(Debug, Eq)

///|
/// Target platform represented by an OCI descriptor.
pub(all) struct Platform {
  os : String
  architecture : String
  variant : String?
  os_version : String?
} derive(Debug, Eq)

///|
/// Reference to immutable content in an OCI layout.
pub(all) struct Descriptor {
  media_type : String
  digest : Digest
  size : Int64
  annotations : Array[KeyValue]
  platform : Platform?
} derive(Debug, Eq)

///|
/// Runtime settings written into an OCI image configuration.
pub(all) struct RuntimeConfig {
  user : String?
  env : Array[KeyValue]
  entrypoint : Array[String]
  cmd : Array[String]
  working_dir : String
  labels : Array[KeyValue]
  exposed_ports : Array[String]
  volumes : Array[String]
  stop_signal : String?
} derive(Debug, Eq)

///|
/// One history record associated with an image layer.
pub(all) struct History {
  created : String?
  created_by : String?
  author : String?
  comment : String?
  empty_layer : Bool
} derive(Debug, Eq)

///|
/// Parsed image configuration required by MoonOCI.
pub(all) struct ImageConfig {
  created : String?
  author : String?
  platform : Platform
  runtime : RuntimeConfig
  diff_ids : Array[Digest]
  history : Array[History]
} derive(Debug, Eq)

///|
/// OCI image manifest for one platform image.
pub(all) struct ImageManifest {
  schema_version : Int32
  media_type : String
  config : Descriptor
  layers : Array[Descriptor]
  annotations : Array[KeyValue]
} derive(Debug, Eq)

///|
/// OCI image index containing one or more manifest descriptors.
pub(all) struct ImageIndex {
  schema_version : Int32
  media_type : String
  manifests : Array[Descriptor]
  annotations : Array[KeyValue]
} derive(Debug, Eq)

///|
/// Severity of a validation finding.
pub(all) enum FindingLevel {
  Error
  Warning
  Info
} derive(Debug, Eq)

///|
/// Structured observation produced by layout verification.
pub(all) struct ValidationFinding {
  level : FindingLevel
  code : String
  message : String
  object_path : String?
} derive(Debug, Eq)

///|
/// Complete verification result.
pub(all) struct VerificationReport {
  findings : Array[ValidationFinding]
  manifests_checked : Int32
  blobs_checked : Int32
  layers_checked : Int32
} derive(Debug, Eq)

///|
/// Whether verification found any error-level findings.
pub fn VerificationReport::is_valid(self : VerificationReport) -> Bool {
  for finding in self.findings {
    if finding.level == FindingLevel::Error {
      return false
    }
  }
  true
}

///|
/// Summary returned after a successful build.
pub(all) struct BuildReport {
  manifest : Descriptor
  config : Descriptor
  layers : Array[Descriptor]
  blobs_written : Int32
  bytes_written : Int64
} derive(Debug, Eq)

///|
/// Root filesystem entry produced by applying layer metadata.
pub(all) struct RootfsEntry {
  path : String
  kind : String
  mode : Int32
  size : Int64
  link_target : String?
  layer_index : Int32
} derive(Debug, Eq)

///|
/// Default Linux/amd64 platform used by the simple CLI form.
pub fn default_platform() -> Platform {
  { os: "linux", architecture: "amd64", variant: None, os_version: None, }
}

///|
/// Default runtime configuration with no command or environment side effects.
pub fn default_runtime_config() -> RuntimeConfig {
  {
    user: None,
    env: [],
    entrypoint: [],
    cmd: [],
    working_dir: "/",
    labels: [],
    exposed_ports: [],
    volumes: [],
    stop_signal: None,
  }
}

///|
pub extend Compression with @debug.Debug::{to_repr}

///|
pub extend Compression with Eq::{not_equal, equal}

///|
pub extend KeyValue with @debug.Debug::{to_repr}

///|
pub extend KeyValue with Eq::{not_equal, equal}

///|
pub extend Platform with @debug.Debug::{to_repr}

///|
pub extend Platform with Eq::{not_equal, equal}

///|
pub extend Descriptor with @debug.Debug::{to_repr}

///|
pub extend Descriptor with Eq::{not_equal, equal}

///|
pub extend RuntimeConfig with @debug.Debug::{to_repr}

///|
pub extend RuntimeConfig with Eq::{not_equal, equal}

///|
pub extend History with @debug.Debug::{to_repr}

///|
pub extend History with Eq::{not_equal, equal}

///|
pub extend ImageConfig with @debug.Debug::{to_repr}

///|
pub extend ImageConfig with Eq::{not_equal, equal}

///|
pub extend ImageManifest with @debug.Debug::{to_repr}

///|
pub extend ImageManifest with Eq::{not_equal, equal}

///|
pub extend ImageIndex with @debug.Debug::{to_repr}

///|
pub extend ImageIndex with Eq::{not_equal, equal}

///|
pub extend FindingLevel with @debug.Debug::{to_repr}

///|
pub extend FindingLevel with Eq::{not_equal, equal}

///|
pub extend ValidationFinding with @debug.Debug::{to_repr}

///|
pub extend ValidationFinding with Eq::{not_equal, equal}

///|
pub extend VerificationReport with @debug.Debug::{to_repr}

///|
pub extend VerificationReport with Eq::{not_equal, equal}

///|
pub extend BuildReport with @debug.Debug::{to_repr}

///|
pub extend BuildReport with Eq::{not_equal, equal}

///|
pub extend RootfsEntry with @debug.Debug::{to_repr}

///|
pub extend RootfsEntry with Eq::{not_equal, equal}
