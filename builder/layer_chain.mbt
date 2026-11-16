///|
/// Compute OCI ChainIDs for every applied prefix of a DiffID sequence.
/// An empty sequence has no ChainID. Each input must be a valid SHA-256 digest.
pub fn layer_chain_ids(
  diff_ids : Array[@model.Digest],
) -> Array[@model.Digest] raise @model.MoonOciError {
  let output : Array[@model.Digest] = []
  for diff_id in diff_ids {
    let diff_id = @model.Digest::parse(diff_id.to_string())
    let next = match output.last() {
      None => diff_id
      Some(previous) =>
        @digest.sha256(
          @utf8.encode(previous.to_string() + " " + diff_id.to_string()),
        )
    }
    output.push(next)
  }
  output
}

///|
/// Descriptor and uncompressed filesystem identities for one layer position.
pub(all) struct LayerIdentity {
  descriptor : @model.Descriptor
  diff_id : @model.Digest
  chain_id : @model.Digest
}

///|
/// Inspect only a verified, explicitly selected image manifest.
pub fn layer_chain_from_manifest(
  source : @layout.MemoryLayout,
  descriptor : @model.Descriptor,
) -> Array[LayerIdentity] raise @model.MoonOciError {
  let manifest = require_root_manifest(source, descriptor)
  let config = @codec.decode_config(source.require_blob(manifest.config))
  let chain = layer_chain_ids(config.diff_ids)
  manifest.layers.mapi((index, descriptor) => {
    descriptor,
    diff_id: config.diff_ids[index],
    chain_id: chain[index],
  })
}
