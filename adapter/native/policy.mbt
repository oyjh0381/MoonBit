///|
/// Read a caller-owned policy with a bounded file handle and strict decoder.
pub async fn load_release_policy(path : String) -> @policy.ReleasePolicy {
  @policy.decode_release_policy(read_bounded_file(path, 65536))
}

///|
pub async fn load_rollout_policy(path : String) -> @rollout.RolloutPolicy {
  @rollout.decode_policy(read_rollout_policy_document(path))
}

///|
pub async fn read_rollout_policy_document(path : String) -> Bytes {
  read_bounded_file(path, 65536)
}

///|
pub async fn load_referrer_lock(
  path : String,
  expected : @model.Digest,
) -> @registry.ReferrerLock {
  @registry.decode_referrer_lock(
    read_bounded_file(path, @registry.MaxReferrerLockBytes),
    expected,
  )
}
