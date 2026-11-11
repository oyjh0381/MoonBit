///|
test "referrer lock binds exact bytes and preserves a reusable ordered selection" {
  let root = @digest.sha256(b"index")
  let subject = @digest.sha256(b"child")
  let a = @digest.sha256(b"a")
  let b = @digest.sha256(b"b")
  let first = @registry.ReferrerLock::new(root, subject, [a, b])
  let reversed = @registry.ReferrerLock::new(root, subject, [b, a])
  assert_eq(first.encode(), reversed.encode())
  assert_eq(first.pin(), reversed.pin())
  let decoded = @registry.decode_referrer_lock(first.encode(), first.pin())
  assert_eq(decoded.root(), root)
  assert_eq(decoded.subject(), subject)
  assert_eq(decoded.selection().pins(), first.selection().pins())
  assert_true(decoded.selection(exact_listing=true).exact_listing())
  let rejected = try {
    ignore(@registry.decode_referrer_lock(first.encode() + b"\n", first.pin()))
    false
  } catch {
    @model.DigestMismatch(_) => true
    _ => false
  }
  assert_true(rejected)
}

///|
test "referrer lock rejects unknown fields and duplicate keys even when pinned" {
  for
    bytes in [
      b"{\"schema\":\"moonoci.referrer-lock.v1\",\"root\":\"ignored\",\"subject\":\"ignored\",\"attachments\":[],\"extra\":true}",
      b"{\"schema\":\"moonoci.referrer-lock.v1\",\"root\":\"first\",\"root\":\"second\",\"subject\":\"ignored\",\"attachments\":[]}",
    ] {
    let rejected = try {
      ignore(@registry.decode_referrer_lock(bytes, @digest.sha256(bytes)))
      false
    } catch {
      @model.InvalidJson(_) => true
      _ => false
    }
    assert_true(rejected)
  }
}
