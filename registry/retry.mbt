///|
/// Read-only request retry policy. HTTP-date Retry-After is not guessed without
/// a wall clock: return None rather than retrying before the server's deadline.
pub fn retry_delay(
  status : Int32,
  headers : Array[@model.KeyValue],
  attempt : Int32,
  max_retries~ : Int32 = 2,
  max_delay_ms~ : Int32 = 5000,
) -> Int32? raise @model.MoonOciError {
  if attempt < 0 ||
    max_retries < 0 ||
    max_retries > 8 ||
    max_delay_ms < 0 ||
    max_delay_ms > 60000 {
    raise @model.InvalidArgument("invalid read-only retry budget")
  }
  if attempt >= max_retries ||
    ![0, 408, 429, 500, 502, 503, 504].contains(status) {
    return None
  }
  if single_header(headers, "retry-after") is Some(value) {
    if value.is_empty() {
      return None
    }
    for ch in value {
      if ch < '0' || ch > '9' {
        return None
      }
    }
    let seconds = @string.parse_int64(value) catch { _ => return None }
    if seconds > max_delay_ms.to_int64() / 1000L {
      return None
    }
    return Some((seconds * 1000L).to_int())
  }
  let mut delay = 250
  for _ in 0..<attempt {
    delay *= 2
  }
  Some(if delay > max_delay_ms { max_delay_ms } else { delay })
}
