///|
/// Content-addressed identifier in `algorithm:encoded` form.
pub(all) struct Digest {
  algorithm : String
  encoded : String
} derive(Debug, Eq)

///|
/// Construct a validated SHA-256 digest from its lowercase hexadecimal value.
pub fn Digest::sha256(encoded : String) -> Digest raise MoonOciError {
  if encoded.length() != 64 {
    raise InvalidDigest(
      "sha256 digest must contain exactly 64 hexadecimal characters",
    )
  }
  for c in encoded {
    if !c.is_ascii_hexdigit() || c.is_ascii_uppercase() {
      raise InvalidDigest(
        "sha256 digest must use lowercase hexadecimal characters",
      )
    }
  }
  { algorithm: "sha256", encoded }
}

///|
/// Parse the OCI digest syntax supported by v0.1.
pub fn Digest::parse(value : String) -> Digest raise MoonOciError {
  match value.split_once(":") {
    Some((algorithm, encoded)) => {
      if algorithm != "sha256" {
        raise Unsupported("only sha256 digests are supported in v0.1")
      }
      Digest::sha256(encoded.to_owned())
    }
    None => raise InvalidDigest("digest must have algorithm:encoded syntax")
  }
}

///|
/// Render a digest in OCI descriptor syntax.
pub fn Digest::to_string(self : Digest) -> String {
  self.algorithm + ":" + self.encoded
}

///|
/// Content-store relative path for this digest.
pub fn Digest::blob_path(self : Digest) -> String {
  "blobs/" + self.algorithm + "/" + self.encoded
}
