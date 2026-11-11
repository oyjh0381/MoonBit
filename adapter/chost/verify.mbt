///|
fn verify_entity_bytes(data : Bytes, pin : Bytes, kind : Int32) -> Int32 {
  let text = @utf8.decode(pin) catch { _ => return 2 }
  let expected = @model.Digest::parse(text) catch { _ => return 2 }
  if @digest.sha256(data) != expected {
    return 3
  }
  let valid = try {
    match kind {
      1 => {
        let index = @codec.decode_index(data)
        index.schema_version == 2 && index.media_type == @model.media_type_index
      }
      2 => {
        let manifest = @codec.decode_manifest(data)
        manifest.schema_version == 2 &&
        manifest.media_type == @model.media_type_manifest
      }
      _ => true
    }
  } catch {
    _ => false
  }
  if valid {
    0
  } else {
    4
  }
}

///|
#external
pub type HostBuffer

///|
extern "C" fn buffer_is_null(buffer : HostBuffer) -> Bool = "moonoci_host_buffer_is_null"

///|
extern "C" fn copy_buffer(buffer : HostBuffer, size : Int32) -> Bytes = "moonoci_host_copy_buffer"

///|
#export_name("moonoci_c_abi_version")
pub fn abi_version() -> Int32 {
  1
}

///|
/// Check a pinned blob or parse a pinned OCI index/manifest from C.
/// Both buffers remain caller-owned. Each readable range is copied once.
#export_name("moonoci_verify_entity")
pub fn verify_entity(
  data : HostBuffer,
  data_size : UInt64,
  pin : HostBuffer,
  pin_size : UInt64,
  kind : Int32,
) -> Int32 {
  if pin_size != 71UL ||
    kind < 0 ||
    kind > 2 ||
    buffer_is_null(pin) ||
    (data_size != 0UL && buffer_is_null(data)) {
    return 2
  }
  if data_size > 16777216UL {
    return 5
  }
  verify_entity_bytes(
    copy_buffer(data, data_size.to_int()),
    copy_buffer(pin, 71),
    kind,
  )
}
