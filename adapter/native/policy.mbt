///|
/// Read a caller-owned policy with a bounded file handle and strict decoder.
pub async fn load_release_policy(path : String) -> @policy.ReleasePolicy {
  @policy.decode_release_policy(read_bounded_file(path, 65536))
}
