///|
/// Optional normalized metadata applied to entries read from a Layer Source.
pub(all) struct MetadataSpec {
  mode : Int32?
  uid : Int32?
  gid : Int32?
  mtime : Int64?
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
  schema_version : Int32
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
  { mode: None, uid: None, gid: None, mtime: None, preserve_mtime: false, }
}

///|
pub extend MetadataSpec with @debug.Debug::{to_repr}

///|
pub extend MetadataSpec with Eq::{not_equal, equal}

///|
pub extend LayerSpec with @debug.Debug::{to_repr}

///|
pub extend LayerSpec with Eq::{not_equal, equal}

///|
pub extend OutputSpec with @debug.Debug::{to_repr}

///|
pub extend OutputSpec with Eq::{not_equal, equal}

///|
pub extend BuildSpec with @debug.Debug::{to_repr}

///|
pub extend BuildSpec with Eq::{not_equal, equal}
