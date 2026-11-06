///|
test "fractional and overflowing schema versions must not truncate to accepted integers" {
  for
    input in [
      b"{\"schemaVersion\":2.5,\"manifests\":[]}", b"{\"schemaVersion\":2147483648,\"manifests\":[]}",
      b"{\"schemaVersion\":1e9999,\"manifests\":[]}",
    ] {
    let rejected = try {
      ignore(@codec.decode_index(input))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  assert_eq(
    @codec.decode_index(b"{\"schemaVersion\":2.0,\"manifests\":[]}").schema_version,
    2,
  )
}

///|
test "lossless JSON mode preserves extension number lexemes" {
  let input = b"{\"serial\":9007199254740993,\"decimal\":1.0000000000000000001,\"large\":1e9999}"
  let output = @codec.parse_json_document(input, preserve_number_repr=true).stringify()
  assert_true(output.contains("9007199254740993"))
  assert_true(output.contains("1.0000000000000000001"))
  assert_true(output.contains("1e9999"))
}
