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

///|
test "bundle promotion reviews a previous bundle and pins the entire candidate evidence set" {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"stable"),
    ]),
  )
  let subject = image.report.manifest
  let payloads : Array[@artifacts.ArtifactPayload] = [
    { media_type: "application/json", data: b"{}", annotations: [], },
  ]
  let first = @artifacts.attach(
    image.layout,
    subject,
    "application/spdx+json",
    payloads,
  )
  let next = @artifacts.attach(
    first.layout,
    subject,
    "application/in-toto+json",
    payloads,
    reference="proof",
  )
  let policy = promotion_policy(first.layout, next.layout)
  let origin = @registry.RegistryOrigin::parse("https://registry.example")
  let pins = [first.descriptor.digest, next.descriptor.digest]
  let approved = @promotion.prepare_bundle(
    first.layout,
    next.layout,
    policy,
    "latest",
    origin,
    "team/app",
    "stable",
    pins,
  )
  let equivalent = @promotion.prepare_bundle(
    first.layout,
    next.layout,
    policy,
    "latest",
    origin,
    "team/app",
    "stable",
    [pins[1], pins[0]],
  )
  assert_eq(approved.pin(), equivalent.pin())
  assert_eq(approved.bundle().unwrap().attachments().length(), 2)
  let changed = @promotion.prepare_bundle(
    first.layout,
    next.layout,
    policy + b"\n",
    "latest",
    origin,
    "team/app",
    "stable",
    pins,
  )
  assert_eq(approved.bundle().unwrap().pin(), changed.bundle().unwrap().pin())
  assert_true(approved.pin() != changed.pin())

  let index = @codec.decode_index(next.layout.index())
  let hidden = @layout.MemoryLayout::from_untrusted_parts(
    next.layout.marker(),
    @codec.encode_index({
      ..index,
      manifests: index.manifests.filter(item => item.digest != pins[1]),
    }),
    next.layout
    .blob_records()
    .map(record => (record.descriptor(), record.data())),
  )
  for (source, selected) in [(next.layout, [pins[0]]), (hidden, pins)] {
    let rejected = try {
      ignore(
        @promotion.prepare_bundle(
          first.layout,
          source,
          promotion_policy(first.layout, source),
          "latest",
          origin,
          "team/app",
          "stable",
          selected,
        ),
      )
      false
    } catch {
      @model.InvalidArgument(_) => true
      _ => false
    }
    assert_true(rejected)
  }
}
