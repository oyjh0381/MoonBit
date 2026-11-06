///|
test "sha256 known vector" {
  inspect(
    @digest.sha256(b"abc").to_string(),
    content="sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
}

///|
test "incremental sha256 equals one-shot" {
  let state = @digest.Sha256::new()
  state.update(b"ab")
  state.update(b"c")
  assert_eq(state.length(), 3L)
  assert_eq(state.finish(), @digest.sha256(b"abc"))
}
