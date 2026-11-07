///|
async test "Native session restarts from verified files and publishes only complete pinned bytes" {
  ensure_test_build_root()
  let root = "_build/native-chunk-session"
  if @fs.exists(root) {
    @fs.rmdir(root, recursive=true)
  }
  @fs.mkdir(root)
  @fs.write_file(root + "/source", b"abcdefghij", create_mode=CreateNew)
  let plan = @native.create_chunk_plan(root + "/source", 4, root + "/plan.json")
  let session = root + "/session"
  @native.start_transfer(root + "/plan.json", plan.digest(), session)
  for index in [2, 0] {
    let path = root + "/chunk-" + index.to_string()
    @native.export_transfer_chunk(
      root + "/source",
      root + "/plan.json",
      plan.digest(),
      index,
      path,
    )
    @native.receive_transfer_chunk(session, plan.digest(), index, path)
    @native.receive_transfer_chunk(session, plan.digest(), index, path)
  }
  let progress = @native.transfer_progress(session, plan.digest())
  assert_eq(progress.missing, [1])
  assert_eq(progress.received_bytes, 6L)
  let rejected = try {
    @native.finish_transfer(session, plan.digest(), root + "/output")
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_false(@fs.exists(root + "/output"))
  assert_false(@fs.exists(root + "/output.moonoci-partial"))
  @native.export_transfer_chunk(
    root + "/source",
    root + "/plan.json",
    plan.digest(),
    1,
    root + "/chunk-1",
  )
  @native.receive_transfer_chunk(session, plan.digest(), 1, root + "/chunk-1")
  assert_true(@native.transfer_progress(session, plan.digest()).complete())
  @native.finish_transfer(session, plan.digest(), root + "/output")
  assert_eq(@fs.read_file(root + "/output").binary(), b"abcdefghij")
  @fs.write_file(session + "/chunks/0", b"fake", create_mode=TruncateExisting)
  let rejected = try {
    ignore(@native.transfer_progress(session, plan.digest()))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let rejected = try {
    @native.finish_transfer(session, plan.digest(), root + "/rejected")
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_false(@fs.exists(root + "/rejected"))
  assert_eq(@fs.read_file(root + "/output").binary(), b"abcdefghij")
  @fs.rmdir(root, recursive=true)
}
