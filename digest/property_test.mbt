///|
test "property: incremental SHA-256 equals one-shot hashing" {
  @quickcheck.quick_check_fn((value : String) => {
    let data = @utf8.encode(value)
    let midpoint = data.length() / 2
    let state = Sha256::new()
    state.update(data[0:midpoint].to_owned())
    state.update(data[midpoint:].to_owned())
    state.finish() == sha256(data)
  })
}
