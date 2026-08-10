///|
/// Optional normalized metadata applied to entries read from a Layer Source.
pub(all) struct MetadataSpec {
  mode : Int?
  uid : Int?
  gid : Int?
  mtime : Int64?
  preserve_mode : Bool
  preserve_ownership : Bool
  preserve_mtime : Bool
} derive(Debug, Eq)

///|
/// One declarative filesystem changeset in a Build Specification.
pub(all) struct LayerSpec {
  source : String
  compression : @model.Compression
  remove : Array[String]
  opaque_dirs : Array[String]
  exclude : Array[String]
  ignore_file : String?
  metadata : MetadataSpec
} derive(Debug, Eq)

///|
/// Destination settings for a Native build.
pub(all) struct OutputSpec {
  layout : String
} derive(Debug, Eq)

///|
/// Strict schemaVersion 1 input consumed by MoonOCI.
pub(all) struct BuildSpec {
  schema_version : Int
  reference : String
  platform : @model.Platform
  layers : Array[LayerSpec]
  runtime : @model.RuntimeConfig
  created : String?
  author : String?
  annotations : Array[@model.KeyValue]
  output : OutputSpec
} derive(Debug, Eq)

///|
pub fn default_metadata_spec() -> MetadataSpec {
  {
    mode: None,
    uid: None,
    gid: None,
    mtime: None,
    preserve_mode: false,
    preserve_ownership: false,
    preserve_mtime: false,
  }
}
