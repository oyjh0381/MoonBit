///|
test "Statement binding matches SHA-256 among multiple subjects and binds raw bytes" {
  let expected = @digest.sha256(b"image")
  let input = @utf8.encode(
    "{\"_type\":\"https://in-toto.io/Statement/v1\",\"predicateType\":\"https://example.org/build/v1\",\"subject\":[{\"digest\":{\"sha512\":\"unused\"}},{\"name\":\"image\",\"digest\":{\"sha256\":" +
    Json::string(expected.encoded).stringify() +
    "}}]}",
  )
  let observation = @artifacts.verify_statement(
    input, expected, "https://example.org/build/v1",
  )
  assert_eq(observation.subject, expected)
  assert_eq(observation.payload, @digest.sha256(input))
  assert_eq(observation.subjects_checked, 2)
  let wrong = try {
    ignore(
      @artifacts.verify_statement(
        input,
        @digest.sha256(b"different"),
        "https://example.org/build/v1",
      ),
    )
    false
  } catch {
    @model.DigestMismatch(_) => true
    _ => false
  }
  assert_true(wrong)
}

///|
test "Statement verification refuses wrong predicates malformed subjects and duplicate keys" {
  let expected = @digest.sha256(b"image")
  let prefix = "{\"_type\":\"https://in-toto.io/Statement/v1\",\"predicateType\":\"urn:test:build\",\"subject\":"
  let match_subject = "{\"digest\":{\"sha256\":\"" + expected.encoded + "\"}}"
  for
    document in [
      prefix + "[]}",
      prefix + "[{\"name\":\"image\"}]}",
      prefix + "[" + match_subject + ",{\"digest\":{\"sha256\":\"bad\"}}]}",
      prefix + "[" + match_subject + "],\"predicate\":null}",
      prefix +
      "[{\"digest\":{\"sha256\":\"" +
      expected.encoded +
      "\",\"sha256\":\"" +
      expected.encoded +
      "\"}}]}",
      prefix + "[" + match_subject + "],\"predicateType\":\"urn:test:other\"}",
    ] {
    let rejected = try {
      ignore(
        @artifacts.verify_statement(
          @utf8.encode(document),
          expected,
          "urn:test:build",
        ),
      )
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  let wrong_type = try {
    ignore(
      @artifacts.verify_statement(
        @utf8.encode(prefix + "[" + match_subject + "]}"),
        expected,
        "urn:test:other",
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(wrong_type)
}
