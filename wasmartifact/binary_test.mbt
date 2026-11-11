///|
test "recognize core and component headers and frame sections" {
  let core = @wasmartifact.inspect_binary(
    b"\x00asm\x01\x00\x00\x00\x00\x81\x00\x00",
  )
  assert_true(core.kind is @wasmartifact.CoreModule)
  assert_eq(core.sections, 1)
  let component = @wasmartifact.inspect_binary(b"\x00asm\x0d\x00\x01\x00")
  assert_true(component.kind is @wasmartifact.Component)
  assert_eq(component.sections, 0)
}

///|
test "reject truncated and overflowing Wasm framing" {
  for
    bad in [
      b"\x00asm\x01", b"\x00asm\x01\x00\x00\x00\x00", b"\x00asm\x01\x00\x00\x00\x00\x02\x00",
      b"\x00asm\x01\x00\x00\x00\x00\xff\xff\xff\xff\x10", b"\x00asm\x01\x00\x00\x00\x00\x80\x80\x80\x80\x80",
    ] {
    let invalid = try {
      ignore(@wasmartifact.inspect_binary(bad))
      false
    } catch {
      @model.InvalidArgument(_) => true
      _ => false
    }
    assert_true(invalid)
  }
  let unsupported = try {
    ignore(@wasmartifact.inspect_binary(b"\x00asm\x0e\x00\x01\x00"))
    false
  } catch {
    @model.Unsupported(_) => true
    _ => false
  }
  assert_true(unsupported)
}
