///|
test "artifact manifest codec retains type subject payload order and deterministic annotations" {
  let layout = @layout.MemoryLayout::new()
  let config = layout.put_blob(@artifacts.empty_media_type, b"{}")
  let payload = layout.put_blob(
    "application/spdx+json", b"{\"spdxVersion\":\"SPDX-2.3\"}",
  )
  let manifest : @artifacts.ArtifactManifest = {
    artifact_type: "application/spdx+json",
    config,
    payloads: [payload],
    subject: Some(payload),
    annotations: [{ key: "z", value: "last", }, { key: "a", value: "first", }],
  }
  let wire = @artifacts.encode_manifest(manifest)
  let decoded = @artifacts.decode_manifest(wire)
  assert_eq(decoded.artifact_type, "application/spdx+json")
  assert_eq(decoded.subject, Some(payload))
  assert_eq(decoded.payloads, [payload])
  assert_eq(
    wire,
    @artifacts.encode_manifest({
      ..manifest,
      annotations: manifest.annotations.rev(),
    }),
  )
  assert_eq(wire, @artifacts.encode_manifest(decoded))
}

///|
test "artifact media names reject wildcards parameters empty names and control characters" {
  for
    name in [
      "", "application", "application/*", "a/b/c", "application/json; charset=utf-8",
      "/json", "a/\n",
    ] {
    let rejected = try {
      @artifacts.validate_media_type(name)
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  @artifacts.validate_media_type("application/vnd.in-toto+json")
}
