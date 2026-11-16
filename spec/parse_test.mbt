///|
test "minimal Build Specification applies deterministic defaults" {
  let spec = @spec.parse_build_spec(
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
    #|    "opaque":["/cache","/"],
    #|    "exclude":["tmp/**"],
    #|    "ignoreFile":".moonociignore",
    #|    "metadata":{"mode":493,"uid":1,"gid":2,"mtime":0}
    #|  }],
    #|  "config":{"env":{"Z":"2","A":"1"},"entrypoint":["/app"],"workingDir":"/work"},
    #|  "annotations":{"org.example":"demo"},
    #|  "output":{"layout":"dist/image"}
    #|}
  let spec = @spec.parse_build_spec(@utf8.encode(json))
  assert_eq(spec.platform.architecture, "arm64")
  assert_eq(spec.layers[0].compression, @model.Compression::Gzip)
  assert_eq(spec.layers[0].remove, ["old"])
  assert_eq(spec.layers[0].opaque_dirs, ["cache", "/"])
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
test "Build Specification rejects unsupported host metadata preservation" {
  assert_spec_fails(
    b"{\"schemaVersion\":1,\"layers\":[{\"source\":\"rootfs\",\"metadata\":{\"preserveMode\":true}}]}",
  )
  assert_spec_fails(
    b"{\"schemaVersion\":1,\"layers\":[{\"source\":\"rootfs\",\"metadata\":{\"preserveOwnership\":true}}]}",
  )
}

///|
fn assert_spec_fails(data : Bytes) -> Unit raise {
  let mut raised = false
  ignore(@spec.parse_build_spec(data)) catch {
    _ => raised = true
  }
  assert_true(raised)
}

///|
test "build specification validates declared hardlink paths" {
  let spec = @spec.parse_build_spec(
    (
      #|{"schemaVersion":1,"layers":[{"source":"files","hardlinks":{"bin/alias":"bin/tool"}}]}
    )
    |> @utf8.encode,
  )
  assert_eq(spec.layers[0].hardlinks, [{ key: "bin/alias", value: "bin/tool", }])
  for
    declaration in [
      (
        #|{"schemaVersion":1,"layers":[{"source":"files","hardlinks":{"alias":"../file"}}]}
      ),
      (
        #|{"schemaVersion":1,"layers":[{"source":"files","hardlinks":{"alias":"alias"}}]}
      ),
    ] {
    assert_spec_fails(@utf8.encode(declaration))
  }
}

///|
test "sourceTar requires an independent digest and forbids transforms" {
  let parsed = @spec.parse_build_spec(
    (
      #|{"schemaVersion":1,"layers":[{"sourceTar":{"path":"changes.tar","diffId":"sha256:0000000000000000000000000000000000000000000000000000000000000000"},"compression":"gzip"}]}
    )
    |> @utf8.encode,
  )
  assert_eq(parsed.layers[0].source, "changes.tar")
  assert_true(parsed.layers[0].tar_source is Some(Raw(_)))
  for
    layer in [
      (
        #|{"sourceTar":{"path":"changes.tar"}}
      ),
      (
        #|{"sourceTar":{"path":"changes.tar","diffId":"bad"}}
      ),
      (
        #|{"source":"files","sourceTar":{"path":"changes.tar","diffId":"bad"}}
      ),
      (
        #|{"sourceTar":{"path":"changes.tar","diffId":"sha256:0000000000000000000000000000000000000000000000000000000000000000"},"remove":[]}
      ),
    ] {
    assert_spec_fails(
      @utf8.encode("{\"schemaVersion\":1,\"layers\":[" + layer + "]}"),
    )
  }
}

///|
test "gzip layer source requires both pins and preserves transport encoding" {
  let pin = "sha256:" + "1".repeat(64)
  let layer =
    #|{"sourceTar":{"path":"layer.tgz","encoding":"gzip","blobDigest":"PIN","diffId":"PIN"}}
  let layer = layer.replace_all(old="PIN", new=pin)
  let parsed = @spec.parse_build_spec(
    @utf8.encode("{\"schemaVersion\":1,\"layers\":[" + layer + "]}"),
  )
  assert_true(parsed.layers[0].tar_source is Some(Gzip(_, _)))
  let before_close = layer[:layer.length() - 1].to_owned()
  assert_spec_fails(
    @utf8.encode(
      "{\"schemaVersion\":1,\"layers\":[" +
      before_close +
      ",\"compression\":\"gzip\"}]}",
    ),
  )
}
