///|
test "upload closure orders shared layers and nested manifests before the root" {
  let a = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"same"),
    ]),
  )
  let b = @builder.build_single_layer({
    ..@builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"same"),
    ]),
    platform: { ..@model.default_platform(), architecture: "arm64", },
  })
  for blob in b.layout.blob_records() {
    ignore(a.layout.put_blob(blob.descriptor().media_type, blob.data()))
  }
  let index = @codec.decode_index(a.layout.index())
  let child = a.layout.put_blob(
    @model.media_type_index,
    @codec.encode_index({ ..index, manifests: [b.report.manifest], }),
  )
  let root = a.layout.put_blob(
    @model.media_type_index,
    @codec.encode_index({
      ..index,
      manifests: [a.report.manifest, child, child],
    }),
    annotations=[{ key: @model.annotation_ref_name, value: "release", }],
  )
  a.layout.set_index(@codec.encode_index({ ..index, manifests: [root], }))
  let catalog = @lifecycle.catalog(a.layout, @digest.sha256(a.layout.index()))
  let upload = catalog.upload_closure("release")
  assert_eq(upload.root.digest, root.digest)
  assert_eq(upload.manifests.map(item => item.digest), [
    a.report.manifest.digest,
    b.report.manifest.digest,
    child.digest,
    root.digest,
  ])
  assert_eq(upload.blobs.map(item => item.digest), [
    a.report.config.digest,
    a.report.layers[0].digest,
    b.report.config.digest,
  ])
  upload.manifests[3].annotations.clear()
  assert_eq(
    catalog.upload_closure("release").manifests[3].annotations.length(),
    1,
  )
}
