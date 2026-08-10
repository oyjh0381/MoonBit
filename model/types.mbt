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
  schema_version : Int
  media_type : String
  config : Descriptor
  layers : Array[Descriptor]
  annotations : Array[KeyValue]
} derive(Debug, Eq)

///|
/// OCI image index containing one or more manifest descriptors.
pub(all) struct ImageIndex {
  schema_version : Int
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
  manifests_checked : Int
  blobs_checked : Int
  layers_checked : Int
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
  blobs_written : Int
  bytes_written : Int64
} derive(Debug, Eq)

///|
/// Root filesystem entry produced by applying layer metadata.
pub(all) struct RootfsEntry {
  path : String
  kind : String
  mode : Int
  size : Int64
  link_target : String?
  layer_index : Int
} derive(Debug, Eq)

///|
/// Default Linux/amd64 platform used by the simple CLI form.
pub fn default_platform() -> Platform {
  { os: "linux", architecture: "amd64", variant: None, os_version: None }
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
