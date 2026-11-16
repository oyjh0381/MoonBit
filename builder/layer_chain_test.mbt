///|
test "OCI ChainIDs match independently computed prefix digests" {
  let a = @digest.sha256(b"a")
  let b = @digest.sha256(b"b")
  let c = @digest.sha256(b"c")
  assert_true(@builder.layer_chain_ids([]).is_empty())
  assert_eq(@builder.layer_chain_ids([a]), [a])
  let result = @builder.layer_chain_ids([a, b, c])
  assert_eq(result.map(value => value.to_string()), [
    "sha256:ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb", "sha256:51c0c8ace48498d6f5fee6b0592cc06f2da0f3cbe09c5a34a97dce85c3889676",
    "sha256:2fce7f8ce91bcf0a1428b36e1024639fdbd9469eea762dba98aa749631885106",
  ])
  assert_true(@builder.layer_chain_ids([b, a, c])[2] != result[2])
}
