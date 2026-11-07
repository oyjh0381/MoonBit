///|
async test "pending recovery promotes verified content and preserves corrupt files" {
  ensure_test_build_root()
  let root = "_build/native-chunk-recovery"
  if @fs.exists(root) {
    @fs.rmdir(root, recursive=true)
  }
  @fs.mkdir(root)
  @fs.write_file(root + "/source", b"abcdefgh", create_mode=CreateNew)
  let plan = @native.create_chunk_plan(root + "/source", 4, root + "/plan.json")
  let session = root + "/session"
  @native.start_transfer(root + "/plan.json", plan.digest(), session)
  assert_eq(
    @native.recover_transfer_chunk(session, plan.digest(), 0),
    "missing",
  )
  @fs.write_file(session + "/chunks/0.pending", b"abcd", create_mode=CreateNew)
  assert_eq(
    @native.recover_transfer_chunk(session, plan.digest(), 0),
    "recovered",
  )
  assert_eq(
    @native.recover_transfer_chunk(session, plan.digest(), 0),
    "committed",
  )
  @fs.write_file(session + "/chunks/1.pending", b"bad!", create_mode=CreateNew)
  let failed = try {
    ignore(@native.recover_transfer_chunk(session, plan.digest(), 1))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_eq(@fs.read_file(session + "/chunks/1.pending").binary(), b"bad!")
  assert_false(@fs.exists(session + "/chunks/1"))
  @fs.write_file(
    root + "/output.moonoci-partial",
    b"abcdefgh",
    create_mode=CreateNew,
  )
  @native.recover_transfer_output(session, plan.digest(), root + "/output")
  assert_eq(@fs.read_file(root + "/output").binary(), b"abcdefgh")
  @fs.write_file(
    root + "/bad.moonoci-partial",
    b"abcdFAKE",
    create_mode=CreateNew,
  )
  let failed = try {
    @native.recover_transfer_output(session, plan.digest(), root + "/bad")
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  assert_false(@fs.exists(root + "/bad"))
  assert_eq(@fs.read_file(root + "/bad.moonoci-partial").binary(), b"abcdFAKE")
  @fs.rmdir(root, recursive=true)
}
