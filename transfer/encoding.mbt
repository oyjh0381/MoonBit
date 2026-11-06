///|
pub let max_plan_bytes : Int32 = 8388608

///|
/// MoonOCI-specific transfer metadata, not an OCI manifest or HTTP protocol.
pub fn encode_plan(plan : PreparedTransfer) -> Bytes {
  let hashes = plan.chunks
    .map(d => Json::string(d.to_string()).stringify())
    .join(",")
  @utf8.encode(
    "{\"format\":\"moonoci.chunks.v1\",\"digest\":" +
    Json::string(plan.digest.to_string()).stringify() +
    ",\"size\":\"" +
    plan.size.to_string() +
    "\",\"chunk_bytes\":" +
    plan.chunk_bytes.to_string() +
    ",\"chunks\":[" +
    hashes +
    "]}",
  )
}

///|
/// Decode within metadata and content quotas, then take a validated snapshot.
/// expected must originate in caller-owned release metadata, not this file.
pub fn decode_plan(
  input : Bytes,
  expected : @model.Digest,
  limits~ : ChunkLimits = ChunkLimits::default(),
) -> PreparedTransfer raise @model.MoonOciError {
  limits.validate()
  if input.length() > max_plan_bytes {
    raise @model.ResourceLimitExceeded("chunk plan exceeds 8 MiB")
  }
  let fields = match @codec.parse_json_document(input) {
    Object(fields) => fields
    _ => raise @model.InvalidJson("chunk plan must be an object")
  }
  if fields.length() != 5 {
    raise @model.InvalidJson(
      "chunk plan requires exactly five versioned fields",
    )
  }
  match fields.get("format") {
    Some(String("moonoci.chunks.v1")) => ()
    _ => raise @model.Unsupported("unsupported chunk plan format")
  }
  let digest = match fields.get("digest") {
    Some(String(value)) => @model.Digest::parse(value)
    _ => raise @model.InvalidJson("chunk plan digest must be a string")
  }
  let size = match fields.get("size") {
    Some(String(value)) => {
      let size = @string.parse_int64(value) catch {
        _ => raise @model.InvalidJson("invalid decimal chunk plan size")
      }
      if size.to_string() != value {
        raise @model.InvalidJson("chunk plan size must be canonical decimal")
      }
      size
    }
    _ => raise @model.InvalidJson("chunk plan size must be a decimal string")
  }
  let chunk_bytes = match fields.get("chunk_bytes") {
    Some(Number(value, ..)) =>
      @string.parse_int(value.to_string()) catch {
        _ => raise @model.InvalidJson("chunk_bytes must be an integer")
      }
    _ => raise @model.InvalidJson("chunk_bytes must be a number")
  }
  let chunks = match fields.get("chunks") {
    Some(Array(values)) => {
      if values.length() > limits.max_chunks {
        raise @model.ResourceLimitExceeded("chunk digest count exceeds quota")
      }
      values.map(value => {
        match value {
          String(text) => @model.Digest::parse(text)
          _ => raise @model.InvalidJson("chunk digest must be a string")
        }
      })
    }
    _ => raise @model.InvalidJson("chunks must be an array")
  }
  prepare({ digest, size, chunk_bytes, chunks, }, expected, limits~)
}
