///|
let delta_media_type : String = "application/vnd.moonoci.delta.v1+json"

///|
/// Deterministic MoonOCI transfer tar. This is not an OCI image archive.
pub fn encode_delta(
  envelope : DeltaEnvelope,
  limits~ : TransferLimits = TransferLimits::default(),
) -> Bytes raise @model.MoonOciError {
  check_envelope(envelope, limits)
  let metadata = @codec.encode_index({
    schema_version: 2,
    media_type: delta_media_type,
    manifests: envelope.blobs.map(b => b.descriptor),
    annotations: [
      { key: "moonoci.base", value: envelope.base_index.to_string(), },
      { key: "moonoci.target", value: envelope.target_index.to_string(), },
    ],
  })
  if metadata.length() > limits.max_index_bytes {
    raise @model.ResourceLimitExceeded(
      "transfer descriptor metadata quota exceeded",
    )
  }
  let entries = [
    @archive.TarEntry::file("moonoci-transfer.json", metadata),
    @archive.TarEntry::file("oci-layout", envelope.marker),
    @archive.TarEntry::file("index.json", envelope.index),
  ]
  for blob in envelope.blobs {
    entries.push(
      @archive.TarEntry::file(blob.descriptor.digest.blob_path(), blob.data),
    )
  }
  @archive.write_tar(entries)
}

///|
/// Parse bounded transfer data without extracting files. A trusted target pin
/// is still required by hydrate; decoding alone grants no release authorization.
pub fn decode_delta(
  input : Bytes,
  limits~ : TransferLimits = TransferLimits::default(),
) -> DeltaEnvelope raise @model.MoonOciError {
  if limits.max_blobs < 1 ||
    limits.max_blobs > 100000 ||
    limits.max_total_bytes < 1L ||
    limits.max_blob_bytes < 1L ||
    limits.max_index_bytes < 1 {
    raise @model.InvalidArgument("invalid transfer decoding limits")
  }
  let overhead = (limits.max_blobs.to_int64() + 3L) * 1024L +
    limits.max_index_bytes.to_int64() +
    4096L
  if input.length().to_int64() > limits.max_total_bytes + overhead {
    raise @model.ResourceLimitExceeded("transfer archive byte quota exceeded")
  }
  let files : Map[String, Bytes] = Map([])
  for entry in @archive.read_tar(input, max_entries=limits.max_blobs + 3) {
    if entry.kind != @archive.Regular || files.contains(entry.path) {
      raise @model.InvalidOci(
        "transfer contains nonregular or duplicate member",
      )
    }
    files[entry.path] = entry.data
  }
  let metadata = require_transfer_file(files, "moonoci-transfer.json")
  if metadata.length() > limits.max_index_bytes {
    raise @model.ResourceLimitExceeded(
      "transfer descriptor metadata quota exceeded",
    )
  }
  let decoded = @codec.decode_index(metadata)
  if decoded.schema_version != 2 ||
    decoded.media_type != delta_media_type ||
    decoded.annotations.length() != 2 {
    raise @model.InvalidOci("unsupported transfer format or metadata")
  }
  let annotation = fn(key : String) -> String raise @model.MoonOciError {
    let matches = decoded.annotations.filter(a => a.key == key)
    if matches.length() != 1 {
      raise @model.InvalidOci("missing transfer pin")
    }
    matches[0].value
  }
  let base_index = @model.Digest::parse(annotation("moonoci.base"))
  let target_index = @model.Digest::parse(annotation("moonoci.target"))
  let blobs : Array[DeltaBlob] = []
  let paths : Map[String, Bool] = Map([])
  for descriptor in decoded.manifests {
    let path = descriptor.digest.blob_path()
    if paths.contains(path) {
      raise @model.InvalidOci("duplicate transfer descriptor")
    }
    paths[path] = true
    blobs.push({ descriptor, data: require_transfer_file(files, path), })
  }
  if files.length() != paths.length() + 3 {
    raise @model.InvalidOci("unexpected transfer member")
  }
  let envelope : DeltaEnvelope = {
    base_index,
    target_index,
    blobs,
    marker: require_transfer_file(files, "oci-layout"),
    index: require_transfer_file(files, "index.json"),
  }
  check_envelope(envelope, limits)
  envelope
}

///|
fn require_transfer_file(
  files : Map[String, Bytes],
  name : String,
) -> Bytes raise @model.MoonOciError {
  match files.get(name) {
    Some(data) => data
    None => raise @model.InvalidOci("missing transfer member: " + name)
  }
}
