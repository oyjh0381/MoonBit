///|
async test "Native chunk producer bounds reads and detects changed source before export" {
  let root = "_build/native-chunk-source"
  if @fs.exists(root) {
    @fs.rmdir(root, recursive=true)
  }
  @fs.mkdir(root)
  @fs.write_file(root + "/source", b"abcdefghij", create_mode=CreateNew)
  let plan = @native.create_chunk_plan(root + "/source", 4, root + "/plan.json")
  assert_eq(plan.size(), 10L)
  assert_eq(plan.chunk_count(), 3)
  @native.export_transfer_chunk(
    root + "/source",
    root + "/plan.json",
    plan.digest(),
    2,
    root + "/tail",
  )
  assert_eq(@fs.read_file(root + "/tail").binary(), b"ij")
  @fs.write_file(root + "/source", b"abcdefghiX", create_mode=TruncateExisting)
  let rejected = try {
    @native.export_transfer_chunk(
      root + "/source",
      root + "/plan.json",
      plan.digest(),
      2,
      root + "/bad",
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_false(@fs.exists(root + "/bad"))
  let rejected = try {
    ignore(
      @native.create_chunk_plan(root + "/source", 1, root + "/over.json", limits={
        ..@transfer.ChunkLimits::default(),
        max_chunks: 2,
      }),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_false(@fs.exists(root + "/over.json"))
  @fs.rmdir(root, recursive=true)
}
