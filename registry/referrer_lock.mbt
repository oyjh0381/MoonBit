///|
pub const MaxReferrerLockBytes : Int32 = 16384

///|
/// A portable handoff binds the release root, subject and approved manifests.
/// A recipient can use the same content pins against another trusted origin.
pub struct ReferrerLock {
  priv root : @model.Digest
  priv subject : @model.Digest
  priv approved : ReferrerSelection
}

///|
pub fn ReferrerLock::new(
  root : @model.Digest,
  subject : @model.Digest,
  pins : Array[@model.Digest],
) -> ReferrerLock raise @model.MoonOciError {
  ignore(@model.Digest::parse(root.to_string()))
  ignore(@model.Digest::parse(subject.to_string()))
  { root, subject, approved: ReferrerSelection::new(pins), }
}

///|
pub fn ReferrerLock::root(self : ReferrerLock) -> @model.Digest {
  self.root
}

///|
pub fn ReferrerLock::subject(self : ReferrerLock) -> @model.Digest {
  self.subject
}

///|
pub fn ReferrerLock::selection(
  self : ReferrerLock,
  exact_listing~ : Bool = false,
) -> ReferrerSelection {
  { ..self.approved, exact_listing, }
}

///|
pub fn ReferrerLock::encode(self : ReferrerLock) -> Bytes {
  let value : Json = {
    "schema": "moonoci.referrer-lock.v1",
    "root": Json::string(self.root.to_string()),
    "subject": Json::string(self.subject.to_string()),
    "attachments": Json::array(
      self.approved.pins.map(pin => Json::string(pin.to_string())),
    ),
  }
  @utf8.encode(value.stringify())
}

///|
pub fn ReferrerLock::pin(self : ReferrerLock) -> @model.Digest {
  @digest.sha256(self.encode())
}

///|
/// Verify the independently supplied digest before parsing untrusted lock bytes.
pub fn decode_referrer_lock(
  data : Bytes,
  expected : @model.Digest,
) -> ReferrerLock raise @model.MoonOciError {
  if data.length() > MaxReferrerLockBytes {
    raise @model.ResourceLimitExceeded("referrer lock byte quota exceeded")
  }
  if @digest.sha256(data) != expected {
    raise @model.DigestMismatch("referrer lock document does not match its pin")
  }
  guard @codec.parse_json_document(data) is Object(fields) &&
    fields.length() == 4 &&
    fields.get("schema") == Some(Json::string("moonoci.referrer-lock.v1")) &&
    fields.get("root") is Some(String(root)) &&
    fields.get("subject") is Some(String(subject)) &&
    fields.get("attachments") is Some(Array(attachments)) else {
    raise @model.InvalidJson("unsupported or malformed referrer lock document")
  }
  if attachments.is_empty() || attachments.length() > 128 {
    raise @model.InvalidJson("invalid referrer lock attachment count")
  }
  let pins = attachments.map(value => {
    guard value is String(pin) else {
      raise @model.InvalidJson("referrer lock attachment must be a digest")
    }
    @model.Digest::parse(pin)
  })
  ReferrerLock::new(
    @model.Digest::parse(root),
    @model.Digest::parse(subject),
    pins,
  )
}
