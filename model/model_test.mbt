///|
test "parse and render sha256 digest" {
  let encoded = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  let digest = @model.Digest::parse("sha256:" + encoded)
  inspect(
    digest.to_string(),
    content="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  )
  inspect(
    digest.blob_path(),
    content="blobs/sha256/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  )
}

///|
test "verification report detects errors" {
  let valid : @model.VerificationReport = {
    findings: [],
    manifests_checked: 1,
    blobs_checked: 2,
    layers_checked: 1,
  }
  assert_true(valid.is_valid())
  let invalid : @model.VerificationReport = {
    findings: [
      {
        level: @model.FindingLevel::Error,
        code: "x",
        message: "bad",
        object_path: None,
      },
    ],
    manifests_checked: 0,
    blobs_checked: 0,
    layers_checked: 0,
  }
  assert_false(invalid.is_valid())
}

///|
test "public enum values are available" {
  debug_inspect(
    [@model.Compression::Uncompressed, @model.Compression::Gzip],
    content="[Uncompressed, Gzip]",
  )
  debug_inspect(
    [@model.FindingLevel::Warning, @model.FindingLevel::Info],
    content="[Warning, Info]",
  )
}
