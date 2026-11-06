///|
test "bounded missing batches are deterministic and make progress" {
  let plan = @transfer.plan_bytes(b"abcdefghij", chunk_bytes=4)
  let batch = plan.batch([2, 0, 1], max_chunks=2, max_bytes=8L)
  assert_eq(batch.chunks.map(c => c.index), [0, 1])
  assert_eq(batch.bytes, 8L)
  assert_eq(batch.pending_chunks, 3)
  let tail = plan.batch([2], max_chunks=1, max_bytes=2L)
  assert_eq(tail.chunks[0].offset, 8L)
  assert_eq(tail.bytes, 2L)
  assert_eq(plan.batch([]).chunks.length(), 0)
  for missing in [[-1], [3], [0, 0], [0, 1, 2, 2]] {
    let rejected = try {
      ignore(plan.batch(missing))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  let rejected = try {
    ignore(plan.batch([0], max_bytes=3L))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
