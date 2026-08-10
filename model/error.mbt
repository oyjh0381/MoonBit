///|
/// Stable error categories exposed by the MoonOCI library.
pub(all) suberror MoonOciError {
  InvalidArgument(String)
  InvalidBuildSpec(String)
  InvalidDigest(String)
  InvalidPath(String)
  InvalidJson(String)
  InvalidTar(String)
  InvalidOci(String)
  DigestMismatch(String)
  SizeMismatch(String)
  ResourceLimitExceeded(String)
  IoFailure(String)
  Unsupported(String)
} derive(Debug, Eq)

///|
/// Return a stable machine-readable code for an error category.
pub fn MoonOciError::code(self : MoonOciError) -> String {
  match self {
    InvalidArgument(_) => "MOONOCI_ARGUMENT"
    InvalidBuildSpec(_) => "MOONOCI_BUILD_SPEC"
    InvalidDigest(_) => "MOONOCI_DIGEST"
    InvalidPath(_) => "MOONOCI_PATH"
    InvalidJson(_) => "MOONOCI_JSON"
    InvalidTar(_) => "MOONOCI_TAR"
    InvalidOci(_) => "MOONOCI_OCI"
    DigestMismatch(_) => "MOONOCI_DIGEST_MISMATCH"
    SizeMismatch(_) => "MOONOCI_SIZE_MISMATCH"
    ResourceLimitExceeded(_) => "MOONOCI_RESOURCE_LIMIT"
    IoFailure(_) => "MOONOCI_IO"
    Unsupported(_) => "MOONOCI_UNSUPPORTED"
  }
}

///|
/// Map a library error to the documented CLI exit status.
pub fn MoonOciError::exit_code(self : MoonOciError) -> Int {
  match self {
    InvalidArgument(_) | InvalidBuildSpec(_) => 2
    IoFailure(_) => 3
    InvalidJson(_) | InvalidTar(_) | InvalidOci(_) | Unsupported(_) => 4
    InvalidDigest(_)
    | InvalidPath(_)
    | DigestMismatch(_)
    | SizeMismatch(_)
    | ResourceLimitExceeded(_) => 5
  }
}

///|
/// Human-readable detail carried by the stable error category.
pub fn MoonOciError::message(self : MoonOciError) -> String {
  match self {
    InvalidArgument(message)
    | InvalidBuildSpec(message)
    | InvalidDigest(message)
    | InvalidPath(message)
    | InvalidJson(message)
    | InvalidTar(message)
    | InvalidOci(message)
    | DigestMismatch(message)
    | SizeMismatch(message)
    | ResourceLimitExceeded(message)
    | IoFailure(message)
    | Unsupported(message) => message
  }
}
