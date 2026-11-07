///|
pub let statement_v1 : String = "https://in-toto.io/Statement/v1"

///|
pub let statement_media_type : String = "application/vnd.in-toto+json"

///|
pub(all) struct StatementBinding {
  payload : @model.Digest
  subject : @model.Digest
  predicate_type : String
  subjects_checked : Int32
}

///|
fn statement_object(
  value : Json?,
  field : String,
) -> Map[String, Json] raise @model.MoonOciError {
  match value {
    Some(Object(fields)) => fields
    _ =>
      raise @model.InvalidOci("in-toto Statement requires object at " + field)
  }
}

///|
/// Check a raw Statement v1 against a caller-supplied SHA-256 and exact
/// predicate type. This checks binding only. Treat names, URIs, other digest
/// algorithms and predicate contents as opaque.
pub fn verify_statement(
  input : Bytes,
  subject : @model.Digest,
  predicate_type : String,
) -> StatementBinding raise @model.MoonOciError {
  if input.length() > 1048576 {
    raise @model.ResourceLimitExceeded("in-toto Statement exceeds 1 MiB")
  }
  ignore(@model.Digest::parse(subject.to_string()))
  validate_statement_predicate_type(predicate_type)
  let root = statement_object(Some(@codec.parse_json_document(input)), "$")
  if root.get("_type") != Some(Json::string(statement_v1)) ||
    root.get("predicateType") != Some(Json::string(predicate_type)) {
    raise @model.InvalidOci(
      "in-toto Statement version or predicate type differs",
    )
  }
  match root.get("predicate") {
    None | Some(Object(_)) => ()
    _ =>
      raise @model.InvalidOci(
        "in-toto predicate must be an object when present",
      )
  }
  let subjects = match root.get("subject") {
    Some(Array(values)) if !values.is_empty() => values
    _ =>
      raise @model.InvalidOci(
        "in-toto Statement requires a nonempty subject array",
      )
  }
  if subjects.length() > 1024 {
    raise @model.ResourceLimitExceeded(
      "in-toto Statement subject quota exceeded",
    )
  }
  let mut matched = false
  for item in subjects {
    let item = statement_object(Some(item), "subject entry")
    let digests = statement_object(item.get("digest"), "subject digest set")
    if digests.is_empty() || digests.length() > 32 {
      raise @model.InvalidOci("in-toto subject requires 1..32 digest entries")
    }
    for algorithm, value in digests {
      match value {
        String(encoded) if !algorithm.is_empty() && !encoded.is_empty() =>
          if algorithm == "sha256" && @model.Digest::sha256(encoded) == subject {
            matched = true
          }
        _ =>
          raise @model.InvalidOci(
            "in-toto digest entries must be nonempty strings",
          )
      }
    }
  }
  if !matched {
    raise @model.DigestMismatch(
      "in-toto Statement lacks the expected SHA-256 subject",
    )
  }
  {
    payload: @digest.sha256(input),
    subject,
    predicate_type,
    subjects_checked: subjects.length(),
  }
}

///|
/// Check the caller's exact, visible-ASCII predicate identifier before IO.
pub fn validate_statement_predicate_type(
  value : String,
) -> Unit raise @model.MoonOciError {
  let scheme = match value.split_once(":") {
    Some((scheme, tail)) if !tail.is_empty() && !scheme.is_empty() =>
      scheme.to_owned()
    _ =>
      raise @model.InvalidArgument(
        "in-toto predicate type requires a URI scheme",
      )
  }
  let first = scheme.to_array()[0]
  if first < 'a' || first > 'z' || value.length() > 2048 {
    raise @model.InvalidArgument(
      "invalid in-toto predicate type scheme or length",
    )
  }
  for ch in scheme {
    if !(ch >= 'a' && ch <= 'z') &&
      !(ch >= '0' && ch <= '9') &&
      !"+-.".contains_char(ch) {
      raise @model.InvalidArgument("invalid in-toto predicate type scheme")
    }
  }
  for ch in value {
    if ch <= ' ' || ch >= '\u{007f}' {
      raise @model.InvalidArgument(
        "in-toto predicate type requires visible ASCII",
      )
    }
  }
}
