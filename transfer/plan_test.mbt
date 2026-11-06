///|
test "chunk plan derives contiguous tail and verifies reordered arrivals" {
  let plan = @transfer.plan_bytes(b"abcdefghij", chunk_bytes=4)
  assert_eq(plan.chunk_count(), 3)
  assert_eq(plan.size(), 10L)
  assert_eq(plan.chunk(0).offset, 0L)
  assert_eq(plan.chunk(1).offset, 4L)
  assert_eq(plan.chunk(2).offset, 8L)
  assert_eq(plan.chunk(2).size, 2)
  plan.verify_chunk(2, b"ij")
  plan.verify_chunk(0, b"abcd")
  plan.verify_chunk(1, b"efgh")
  for (index, bytes) in [(0, b"abce"), (2, b"ijk"), (-1, b""), (3, b"")] {
    let failed = try {
      plan.verify_chunk(index, bytes)
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }
}

///|
test "prepared snapshot survives mutation and rejects forged coverage and pins" {
  let digest = @digest.sha256(b"abcdefgh")
  let chunks = [@digest.sha256(b"abcd"), @digest.sha256(b"efgh")]
  let input : @transfer.ChunkPlan = {
    digest,
    size: 8L,
    chunk_bytes: 4,
    chunks,
  }
  let plan = @transfer.prepare(input, digest)
  chunks[0] = @digest.sha256(b"fake")
  plan.verify_chunk(0, b"abcd")
  for
    bad in [
      { ..input, size: 9L, },
      { ..input, size: -1L, },
      { ..input, chunk_bytes: 0, },
      { ..input, chunks: [], },
      { ..input, digest: @digest.sha256(b"other"), },
    ] {
    let failed = try {
      ignore(@transfer.prepare(bad, digest))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }
}

///|
test "empty and exact-multiple sources respect quotas before hashing chunks" {
  assert_eq(@transfer.plan_bytes(b"", chunk_bytes=1).chunk_count(), 0)
  assert_eq(@transfer.plan_bytes(b"abcd", chunk_bytes=2).chunk(1).size, 2)
  let limits = { ..@transfer.ChunkLimits::default(), max_chunks: 1, }
  let rejected = try {
    ignore(@transfer.plan_bytes(b"abc", chunk_bytes=2, limits~))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let huge : @transfer.ChunkPlan = {
    digest: @digest.sha256(b""),
    size: 9223372036854775807L,
    chunk_bytes: 1,
    chunks: [],
  }
  let rejected = try {
    ignore(@transfer.prepare(huge, huge.digest))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
