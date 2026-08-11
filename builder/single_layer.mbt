///|
/// Portable request for the first complete in-memory build path.
pub(all) struct SingleLayerRequest {
  entries : Array[@archive.TarEntry]
  platform : @model.Platform
  runtime : @model.RuntimeConfig
  created : String?
  author : String?
  reference : String
  annotations : Array[@model.KeyValue]
  compression : @model.Compression
} derive(Debug, Eq)

///|
/// Layout and report returned by a portable in-memory build.
pub(all) struct BuildResult {
  layout : @layout.MemoryLayout
  report : @model.BuildReport
} derive(Debug, Eq)

///|
/// Construct a deterministic, single-layer, uncompressed OCI Image Layout.
pub fn build_single_layer(
  request : SingleLayerRequest,
) -> BuildResult raise @model.MoonOciError {
  let result = build_image({
    layers: [
      {
        entries: request.entries,
        remove: [],
        opaque_dirs: [],
        compression: request.compression,
      },
    ],
    platform: request.platform,
    runtime: request.runtime,
    created: request.created,
    author: request.author,
    reference: request.reference,
    annotations: request.annotations,
  })
  { layout: result.layout, report: result.report }
}

///|
/// Recommended defaults for a simple Linux/amd64 image.
pub fn default_single_layer_request(
  entries : Array[@archive.TarEntry],
) -> SingleLayerRequest {
  {
    entries,
    platform: @model.default_platform(),
    runtime: @model.default_runtime_config(),
    created: None,
    author: None,
    reference: "latest",
    annotations: [],
    compression: @model.Compression::Uncompressed,
  }
}
