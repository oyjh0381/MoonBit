///|
/// Ordered final verification; does not retain content or trust a checkpoint's
/// claimed completion. Invalid chunks leave the accepted prefix unchanged.
pub struct TransferVerifier {
  priv plan : PreparedTransfer
  priv state : @digest.Sha256
  priv mut next : Int32
}

///|
pub fn TransferVerifier::new(plan : PreparedTransfer) -> TransferVerifier {
  { plan, state: @digest.Sha256::new(), next: 0, }
}

///|
pub fn TransferVerifier::accept(
  self : TransferVerifier,
  index : Int32,
  data : Bytes,
) -> Unit raise @model.MoonOciError {
  if index != self.next {
    raise @model.InvalidArgument(
      "final verification requires contiguous chunk order",
    )
  }
  self.plan.verify_chunk(index, data)
  self.state.update(data)
  self.next += 1
}

///|
pub fn TransferVerifier::accepted_chunks(self : TransferVerifier) -> Int32 {
  self.next
}

///|
/// Only this check binds individually valid chunks to the expected whole blob.
pub fn TransferVerifier::finish(
  self : TransferVerifier,
) -> @model.Digest raise @model.MoonOciError {
  if self.next != self.plan.chunk_count() ||
    self.state.length() != self.plan.size {
    raise @model.SizeMismatch("transfer is incomplete")
  }
  let actual = self.state.finish()
  if actual != self.plan.digest {
    raise @model.DigestMismatch("assembled whole-content SHA-256 mismatch")
  }
  actual
}
