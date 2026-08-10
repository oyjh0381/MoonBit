///|
async test "Native adapter collects sorted normalized files and exclusions" {
  let root = "_build/moonoci_native_collect"
  if @fs.exists(root) {
    @fs.rmdir(root, recursive=true)
  }
  @fs.mkdir(root + "/sub", recursive=true)
  @fs.write_file(root + "/z.txt", "z", create_mode=CreateOrTruncate)
  @fs.write_file(root + "/sub/a.txt", "a", create_mode=CreateOrTruncate)
  @fs.write_file(root + "/skip.tmp", "skip", create_mode=CreateOrTruncate)
  let layer : @spec.LayerSpec = {
    source: root,
    compression: @model.Compression::Uncompressed,
    remove: [],
    opaque_dirs: [],
    exclude: ["*.tmp"],
    ignore_file: None,
    metadata: @spec.default_metadata_spec(),
  }
  let entries = collect_layer_source(root, layer)
  assert_eq(entries.map(entry => entry.path), ["sub", "sub/a.txt", "z.txt"])
  for entry in entries {
    assert_eq(entry.uid, 0)
    assert_eq(entry.gid, 0)
    assert_eq(entry.mtime, 0L)
  }
  @fs.rmdir(root, recursive=true)
}

///|
async test "Native build writes a complete OCI Image Layout" {
  let root = "_build/moonoci_native_build"
  let output = "_build/moonoci_native_layout"
  let staging = output + ".moonoci-staging"
  for path in [root, output, staging] {
    if @fs.exists(path) {
      @fs.rmdir(path, recursive=true)
    }
  }
  @fs.mkdir(root, recursive=true)
  @fs.write_file(root + "/hello.txt", "hello", create_mode=CreateOrTruncate)
  let spec_path = "_build/moonoci_native_spec.json"
  let document = "{\"schemaVersion\":1,\"ref\":\"native\",\"layers\":[{\"source\":\"" +
    root +
    "\"}],\"output\":{\"layout\":\"" +
    output +
    "\"}}"
  @fs.write_file(spec_path, document, create_mode=CreateOrTruncate)
  let result = build_from_file(spec_path)
  assert_true(@fs.exists(output + "/oci-layout"))
  assert_true(@fs.exists(output + "/index.json"))
  assert_true(
    @fs.exists(output + "/" + result.report.manifest.digest.blob_path()),
  )
  assert_true(@build.verify_memory(result.layout).is_valid())
  let loaded = load_layout(output)
  assert_true(@build.verify_memory(loaded).is_valid())
  assert_eq(@build.rootfs_from_layout(loaded).map(entry => entry.path), [
    "hello.txt",
  ])
  let archive_path = "_build/moonoci_native_layout.tar"
  if @fs.exists(archive_path) {
    @fs.remove(archive_path)
  }
  archive_layout_file(output, archive_path)
  assert_true(@fs.exists(archive_path))
  assert_eq(@fs.read_file(archive_path).binary(), archive_layout_bytes(loaded))
  @fs.rmdir(root, recursive=true)
  @fs.rmdir(output, recursive=true)
  @fs.remove(spec_path)
  @fs.remove(archive_path)
}
