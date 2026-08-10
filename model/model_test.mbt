///|
test "parse and render sha256 digest" {
  let encoded = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  let digest = Digest::parse("sha256:" + encoded)
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
  let valid : VerificationReport = {
    findings: [],
    manifests_checked: 1,
    blobs_checked: 2,
    layers_checked: 1,
  }
  assert_true(valid.is_valid())
  let invalid : VerificationReport = {
    findings: [
      {
        level: FindingLevel::Error,
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
    [Compression::Uncompressed, Compression::Gzip],
    content="[Uncompressed, Gzip]",
  )
  debug_inspect(
    [FindingLevel::Warning, FindingLevel::Info],
    content="[Warning, Info]",
  )
}
