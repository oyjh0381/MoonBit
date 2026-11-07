///|
async test "long-lived host reuses its snapshot but revalidates actual cache content" {
  ensure_test_build_root()
  let root = "_build/native-chunk-host"
  if @fs.exists(root) {
    @fs.rmdir(root, recursive=true)
  }
  @fs.mkdir(root)
  @fs.write_file(root + "/source", b"abcdefgh", create_mode=CreateNew)
  let plan = @native.create_chunk_plan(root + "/source", 4, root + "/plan.json")
  @native.start_transfer(root + "/plan.json", plan.digest(), root + "/session")
  let host = @native.TransferSession::open(root + "/session", plan.digest())
  assert_eq(host.plan().chunk_count(), 2)
  // In-memory snapshot remains stable after a host accidentally edits metadata.
  @fs.write_file(
    root + "/session/plan.json",
    b"{}",
    create_mode=TruncateExisting,
  )
  for index in 0..<2 {
    let path = root + "/chunk-" + index.to_string()
    @native.export_transfer_chunk(
      root + "/source",
      root + "/plan.json",
      plan.digest(),
      index,
      path,
    )
    host.receive(index, path)
  }
  assert_true(host.progress().complete())
  host.finish(root + "/output")
  assert_eq(@fs.read_file(root + "/output").binary(), b"abcdefgh")
  let new_open_rejected = try {
    ignore(@native.TransferSession::open(root + "/session", plan.digest()))
    false
  } catch {
    _ => true
  }
  assert_true(new_open_rejected)
  @fs.write_file(
    root + "/session/chunks/0",
    b"fake",
    create_mode=TruncateExisting,
  )
  let rejected = try {
    ignore(host.progress())
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  @fs.rmdir(root, recursive=true)
}
