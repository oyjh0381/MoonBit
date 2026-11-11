///|
fn promotion_policy(
  base : @layout.MemoryLayout,
  next : @layout.MemoryLayout,
) -> Bytes {
  let value : Json = {
    "schemaVersion": 1,
    "baselineIndex": Json::string(@digest.sha256(base.index()).to_string()),
    "candidateIndex": Json::string(@digest.sha256(next.index()).to_string()),
    "requiredPlatforms": [{ "os": "linux", "architecture": "amd64" }],
  }
  @utf8.encode(value.stringify())
}

///|
test "promotion binds the exact policy document and destination" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"stable"),
    ]),
  )
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  let policy = promotion_policy(image.layout, image.layout)
  let plan = @promotion.prepare(
    image.layout,
    image.layout,
    policy,
    "latest",
    origin,
    "team/app",
    "reviewed",
  )
  let changed_policy = @promotion.prepare(
    image.layout,
    image.layout,
    policy + b"\n",
    "latest",
    origin,
    "team/app",
    "reviewed",
  )
  let other_tag = @promotion.prepare(
    image.layout,
    image.layout,
    policy,
    "latest",
    origin,
    "team/app",
    "other",
  )
  assert_eq(plan.publication().pin(), changed_policy.publication().pin())
  assert_true(plan.pin() != changed_policy.pin())
  assert_true(plan.pin() != other_tag.pin())
}

///|
test "promotion refuses a selected root when another root could be reviewed instead" {
  let a = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"stable"),
    ]),
  )
  let b = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"other"),
    ]),
  )
  let index = @codec.decode_index(a.layout.index())
  let store = a.layout
    .blob_records()
    .map(record => (record.descriptor(), record.data()))
  let records = store +
    b.layout
    .blob_records()
    .filter(record => a.layout.get_blob(record.descriptor().digest) is None)
    .map(record => (record.descriptor(), record.data()))
  let alternate = { ..b.report.manifest, annotations: [], }
  let candidate = @layout.MemoryLayout::from_untrusted_parts(
    a.layout.marker(),
    @codec.encode_index({ ..index, manifests: [a.report.manifest, alternate], }),
    records,
  )
  let rejected = try {
    ignore(
      @promotion.prepare(
        a.layout,
        candidate,
        promotion_policy(a.layout, candidate),
        "latest",
        @registry.RegistryOrigin::parse("https://registry.example"),
        "team/app",
        "reviewed",
      ),
    )
    false
  } catch {
    @model.InvalidArgument(_) => true
    _ => false
  }
  assert_true(rejected)
}
