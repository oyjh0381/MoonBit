///|
pub(all) enum BinaryKind {
  CoreModule
  Component
}

///|
pub(all) struct BinarySummary {
  kind : BinaryKind
  sections : Int32
}

///|
fn read_section_length(
  data : Bytes,
  start : Int32,
) -> (Int64, Int32) raise @model.MoonOciError {
  let mut size = 0L
  for i in 0..<5 {
    if i >= data.length() - start {
      raise @model.InvalidArgument("truncated WebAssembly section length")
    }
    let byte = data[start + i].to_int()
    if i == 4 && byte > 15 {
      raise @model.InvalidArgument("WebAssembly section length exceeds u32")
    }
    size = size | ((byte & 127).to_int64() << (7 * i))
    if byte < 128 {
      return (size, start + i + 1)
    }
  }
  raise @model.InvalidArgument("WebAssembly section length exceeds u32")
}

///|
/// Inspect the supported binary header and top-level section framing.
/// Section contents and runtime semantics require a WebAssembly validator.
pub fn inspect_binary(data : Bytes) -> BinarySummary raise @model.MoonOciError {
  if data.length() < 8 || data[:4] != b"\x00asm"[:] {
    raise @model.InvalidArgument("invalid WebAssembly header")
  }
  let kind = if data[4:8] == b"\x01\x00\x00\x00"[:] {
    CoreModule
  } else if data[4:8] == b"\x0d\x00\x01\x00"[:] {
    Component
  } else {
    raise @model.Unsupported("unsupported WebAssembly binary version or layer")
  }
  let mut cursor = 8
  let mut sections = 0
  while cursor < data.length() {
    let (size, payload) = read_section_length(data, cursor + 1)
    if size > (data.length() - payload).to_int64() {
      raise @model.InvalidArgument("truncated WebAssembly section payload")
    }
    cursor = payload + size.to_int()
    sections += 1
  }
  { kind, sections, }
}
