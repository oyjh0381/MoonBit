///|
test "minimal Build Specification applies deterministic defaults" {
  let spec = parse_build_spec(
    b"{\"schemaVersion\":1,\"layers\":[{\"source\":\"rootfs\"}]}",
  )
  assert_eq(spec.schema_version, 1)
  assert_eq(spec.reference, "latest")
  assert_eq(spec.platform, @model.default_platform())
  assert_eq(spec.layers.length(), 1)
  assert_eq(spec.layers[0].compression, @model.Compression::Uncompressed)
  assert_eq(spec.output.layout, "oci-layout")
}

///|
test "full Build Specification maps supported fields" {
  let json =
    #|{
    #|  "schemaVersion": 1,
    #|  "ref": "demo",
    #|  "platform": {"os":"linux","architecture":"arm64","variant":"v8"},
    #|  "layers": [{
    #|    "source":"rootfs",
    #|    "compression":"gzip",
    #|    "remove":["/old"],
    #|    "opaque":["/cache"],
    #|    "exclude":["tmp/**"],
    #|    "ignoreFile":".moonociignore",
    #|    "metadata":{"mode":493,"uid":1,"gid":2,"mtime":0}
    #|  }],
    #|  "config":{"env":{"Z":"2","A":"1"},"entrypoint":["/app"],"workingDir":"/work"},
    #|  "annotations":{"org.example":"demo"},
    #|  "output":{"layout":"dist/image"}
    #|}
  let spec = parse_build_spec(@utf8.encode(json))
  assert_eq(spec.platform.architecture, "arm64")
  assert_eq(spec.layers[0].compression, @model.Compression::Gzip)
  assert_eq(spec.layers[0].remove, ["old"])
  assert_eq(spec.layers[0].opaque_dirs, ["cache"])
  assert_eq(spec.runtime.env[0].key, "A")
  assert_eq(spec.output.layout, "dist/image")
}

///|
test "Build Specification rejects unknown root field" {
  assert_spec_fails(
    b"{\"schemaVersion\":1,\"layers\":[{\"source\":\"rootfs\"}],\"schemVersion\":1}",
  )
}

///|
test "Build Specification rejects unknown nested field" {
  assert_spec_fails(
    b"{\"schemaVersion\":1,\"layers\":[{\"source\":\"rootfs\",\"compresion\":\"gzip\"}]}",
  )
}

///|
test "Build Specification rejects unsupported version and compression" {
  assert_spec_fails(
    b"{\"schemaVersion\":2,\"layers\":[{\"source\":\"rootfs\"}]}",
  )
  assert_spec_fails(
    b"{\"schemaVersion\":1,\"layers\":[{\"source\":\"rootfs\",\"compression\":\"zstd\"}]}",
  )
}

///|
test "Build Specification rejects unsafe declared paths" {
  assert_spec_fails(
    b"{\"schemaVersion\":1,\"layers\":[{\"source\":\"rootfs\",\"remove\":[\"../../host\"]}]}",
  )
}

///|
test "Build Specification rejects duplicate object keys including escaped forms" {
  assert_spec_fails(
    b"{\"schemaVersion\":1,\"layers\":[{\"source\":\"rootfs\"}],\"ref\":\"one\",\"r\\u0065f\":\"two\"}",
  )
}

///|
fn assert_spec_fails(data : Bytes) -> Unit raise {
  let mut raised = false
  ignore(parse_build_spec(data)) catch {
    _ => raised = true
  }
  assert_true(raised)
}
