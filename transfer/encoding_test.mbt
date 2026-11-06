///|
test "versioned chunk plans roundtrip deterministically and reject ambiguous JSON" {
  let plan = @transfer.plan_bytes(b"abcdefg", chunk_bytes=3)
  let encoded = @transfer.encode_plan(plan)
  let parsed = @transfer.decode_plan(encoded, plan.digest())
  assert_eq(@transfer.encode_plan(parsed), encoded)
  assert_eq(parsed.chunk(2).size, 1)
  for
    bad in [
      b"[]", b"{\"format\":\"moonoci.chunks.v1\",\"format\":\"moonoci.chunks.v1\"}",
      b"{\"format\":\"future\",\"digest\":\"x\",\"size\":\"0\",\"chunk_bytes\":1,\"chunks\":[]}",
    ] {
    let failed = try {
      ignore(@transfer.decode_plan(bad, plan.digest()))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }
  let wrong_pin = try {
    ignore(@transfer.decode_plan(encoded, @digest.sha256(b"other")))
    false
  } catch {
    _ => true
  }
  assert_true(wrong_pin)
}

///|
test "final verifier requires whole digest even when all chunk digests pass" {
  let actual = @transfer.plan_bytes(b"abcdefgh", chunk_bytes=4)
  let forged = @transfer.prepare(
    {
      digest: @digest.sha256(b"abcdFAKE"),
      size: 8L,
      chunk_bytes: 4,
      chunks: [actual.chunk(0).digest, actual.chunk(1).digest],
    },
    @digest.sha256(b"abcdFAKE"),
  )
  let verifier = @transfer.TransferVerifier::new(forged)
  verifier.accept(0, b"abcd")
  verifier.accept(1, b"efgh")
  let failed = try {
    ignore(verifier.finish())
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "failed chunk leaves ordered verifier reusable and empty transfers finish" {
  let plan = @transfer.plan_bytes(b"abcdef", chunk_bytes=3)
  let verifier = @transfer.TransferVerifier::new(plan)
  for (index, bytes) in [(1, b"def"), (0, b"BAD"), (0, b"ab")] {
    let failed = try {
      verifier.accept(index, bytes)
      false
    } catch {
      _ => true
    }
    assert_true(failed)
    assert_eq(verifier.accepted_chunks(), 0)
  }
  verifier.accept(0, b"abc")
  let incomplete = try {
    ignore(verifier.finish())
    false
  } catch {
    _ => true
  }
  assert_true(incomplete)
  verifier.accept(1, b"def")
  assert_eq(verifier.finish(), plan.digest())
  assert_eq(verifier.finish(), plan.digest())
  assert_eq(
    @transfer.TransferVerifier::new(@transfer.plan_bytes(b"")).finish(),
    @digest.sha256(b""),
  )
}
