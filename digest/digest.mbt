///|
/// Incremental SHA-256 state used by streaming adapters.
pub struct Sha256 {
  state : @crypto.SHA256
  mut bytes_seen : Int64
}

///|
/// Create an empty SHA-256 state.
pub fn Sha256::new() -> Sha256 {
  { state: @crypto.SHA256::new(), bytes_seen: 0L, }
}

///|
/// Add one immutable byte chunk to the digest.
pub fn Sha256::update(self : Sha256, data : Bytes) -> Unit {
  self.state.update(data)
  self.bytes_seen += data.length().to_int64()
}

///|
/// Number of bytes accepted by this state.
pub fn Sha256::length(self : Sha256) -> Int64 {
  self.bytes_seen
}

///|
/// Finish without mutating the accumulated state.
pub fn Sha256::finish(self : Sha256) -> @model.Digest {
  let encoded = @crypto.bytes_to_hex_string(self.state.finalize())
  @model.Digest::sha256(encoded) catch {
    _ => abort("internal SHA-256 implementation returned an invalid digest")
  }
}

///|
/// Hash an in-memory byte sequence.
pub fn sha256(data : Bytes) -> @model.Digest {
  let encoded = @crypto.bytes_to_hex_string(@crypto.sha256(data))
  @model.Digest::sha256(encoded) catch {
    _ => abort("internal SHA-256 implementation returned an invalid digest")
  }
}
