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
