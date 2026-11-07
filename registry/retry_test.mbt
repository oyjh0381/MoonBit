///|
test "read-only retries bound attempts backoff and server-requested delays" {
  assert_eq(@registry.retry_delay(503, [], 0), Some(250))
  assert_eq(@registry.retry_delay(429, [], 1), Some(500))
  assert_eq(@registry.retry_delay(503, [], 2), None)
  assert_eq(
    @registry.retry_delay(503, [{ key: "Retry-After", value: "0", }], 0),
    Some(0),
  )
  assert_eq(
    @registry.retry_delay(503, [{ key: "Retry-After", value: "120", }], 0),
    None,
  )
  assert_eq(
    @registry.retry_delay(
      503,
      [{ key: "Retry-After", value: "Fri, 31 Dec 2099 23:59:59 GMT", }],
      0,
    ),
    None,
  )
  assert_eq(
    @registry.retry_delay(
      503,
      [{ key: "Retry-After", value: "999999999999999999999999", }],
      0,
    ),
    None,
  )
  for status in [200, 301, 401, 403, 404, 409] {
    assert_eq(@registry.retry_delay(status, [], 0), None)
  }
  assert_eq(
    @registry.retry_delay(0, [], 7, max_retries=8, max_delay_ms=2000),
    Some(2000),
  )
}
