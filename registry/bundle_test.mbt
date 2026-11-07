///|
test "verified referrer bundle retains exact original metadata and physical deduplication" {
  let source = image().layout
  let fields = match @codec.parse_json_document(source.index()) {
    Object(fields) => fields
    _ => abort("index")
  }
  fields["x-extension"] = Json::string("retained exactly")
  source.set_index(@utf8.encode(Json::object(fields).stringify()))
  let original = source.index()
  let pin = @digest.sha256(original)
  let subject = @codec.decode_index(original).manifests[0]
  let attached = @artifacts.attach(
    source,
    subject,
    "application/spdx+json",
    [
      {
        media_type: "application/json",
        data: b"{\"bill\":1}",
        annotations: [],
      },
    ],
    annotations=[{ key: "tool", value: "fixture", }],
  )
  let advertisements = @artifacts.decode_referrer_page(
    @utf8.encode(
      @artifacts.referrers_json(
        @artifacts.referrers(attached.layout, subject.digest),
      ),
    ),
  )
  let exported = @artifacts.export_artifact(
    attached.layout,
    attached.descriptor,
  )
  let bundle = @registry.assemble_referrer_bundle(
    source,
    pin,
    subject.digest,
    advertisements,
    [exported],
  )
  assert_eq(source.index(), original)
  assert_eq(bundle.layout.get_blob(pin), Some(original))
  assert_eq(bundle.layout.blob_count(), attached.layout.blob_count() + 1)
  assert_true(@artifacts.verify_store(bundle.layout).valid)
  assert_true(
    @artifacts.verify_referrer_page(
      bundle.layout,
      subject.digest,
      advertisements,
    ).valid,
  )
  let returned = @artifacts.payload_bytes(bundle.layout, attached.descriptor, 0)
  assert_eq(returned, b"{\"bill\":1}")
  let empty = @registry.assemble_referrer_bundle(
    source,
    pin,
    subject.digest,
    [],
    [],
  )
  assert_eq(empty.layout.index(), original)
  assert_eq(empty.layout.blob_count(), source.blob_count())
}

///|
test "bundle refuses forged listings roots pins quotas and corrupt physical inputs" {
  let source = image().layout
  let subject = @codec.decode_index(source.index()).manifests[0]
  let attached = @artifacts.attach(source, subject, "application/spdx+json", [])
  let page = @artifacts.decode_referrer_page(
    @utf8.encode(
      @artifacts.referrers_json(
        @artifacts.referrers(attached.layout, subject.digest),
      ),
    ),
  )
  let exported = @artifacts.export_artifact(
    attached.layout,
    attached.descriptor,
  )
  let pin = @digest.sha256(source.index())
  for
    changed in [
      [{ ..page[0], artifact_type: Some("application/forged"), }],
      [{ ..page[0], descriptor: { ..page[0].descriptor, size: 1L, }, }],
      [
        {
          ..page[0],
          descriptor: {
            ..page[0].descriptor,
            annotations: [{ key: "forged", value: "yes", }],
          },
        },
      ],
      [page[0], page[0]],
    ] {
    let parts = if changed.length() == 2 {
      [exported, exported]
    } else {
      [exported]
    }
    let rejected = try {
      ignore(
        @registry.assemble_referrer_bundle(
          source,
          pin,
          subject.digest,
          changed,
          parts,
        ),
      )
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  let rejected = try {
    ignore(
      @registry.assemble_referrer_bundle(
        source,
        @digest.sha256(b"wrong"),
        subject.digest,
        page,
        [exported],
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let rejected = try {
    ignore(
      @registry.assemble_referrer_bundle(
        source,
        pin,
        subject.digest,
        page,
        [exported],
        limits={ ..@registry.PullLimits::default(), max_objects: 1, },
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let records = source
    .blob_records()
    .map(record => (record.descriptor(), record.data()))
  records.push((records[0].0, b"corrupt orphan duplicate"))
  let corrupt = @layout.MemoryLayout::from_untrusted_parts(
    source.marker(),
    source.index(),
    records,
  )
  let rejected = try {
    ignore(
      @registry.assemble_referrer_bundle(corrupt, pin, subject.digest, page, [
        exported,
      ]),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(source.blob_count(), 3)
}

///|
test "a fetched attachment for a different subject cannot enter the bundle" {
  let source = image().layout
  let subject = @codec.decode_index(source.index()).manifests[0]
  let other = @artifacts.build("application/json", [])
  let wrong = @artifacts.build(
    "application/spdx+json",
    [],
    subject=other.descriptor,
  )
  let advertisement : @artifacts.ReferrerAdvertisement = {
    descriptor: { ..wrong.descriptor, annotations: [], },
    artifact_type: Some("application/spdx+json"),
  }
  let rejected = try {
    ignore(
      @registry.assemble_referrer_bundle(
        source,
        @digest.sha256(source.index()),
        subject.digest,
        [advertisement],
        [wrong.layout],
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}

///|
test "index referrers keep original index subjects and reject bad subject size" {
  let source = image().layout
  let pin = @digest.sha256(source.index())
  let subject = @artifacts.resolve_subject(source, pin)
  for valid in [true, false] {
    let link = if valid { subject } else { { ..subject, size: 1L, } }
    let raw = @utf8.encode(
      "{\"schemaVersion\":2,\"mediaType\":\"" +
      @model.media_type_index +
      "\",\"artifactType\":\"application/vnd.test.index-proof\",\"subject\":" +
      @codec.encode_descriptor(link) +
      ",\"manifests\":[]}",
    )
    let fetched = @layout.MemoryLayout::new()
    fetched.set_index(raw)
    let advertisement : @artifacts.ReferrerAdvertisement = {
      descriptor: {
        media_type: @model.media_type_index,
        digest: @digest.sha256(raw),
        size: raw.length().to_int64(),
        annotations: [],
        platform: None,
      },
      artifact_type: Some("application/vnd.test.index-proof"),
    }
    let result = Some(
      @registry.assemble_referrer_bundle(source, pin, pin, [advertisement], [
        fetched,
      ]),
    ) catch {
      _ => None
    }
    if valid {
      let result = result.unwrap()
      assert_eq(result.layout.get_blob(pin), Some(source.index()))
      assert_eq(
        result.layout.get_blob(advertisement.descriptor.digest),
        Some(raw),
      )
      assert_true(@artifacts.verify_store(result.layout).valid)
    } else {
      assert_true(result is None)
    }
  }
}

///|
test "assembling zero discovered attachments still checks source image semantics" {
  let source = image().layout
  let root = @codec.decode_index(source.index())
  let manifest = @codec.decode_manifest(source.require_blob(root.manifests[0]))
  let bad_layer = source.put_blob(@model.media_type_layer_tar, b"not a tar")
  let changed = source.put_blob(
    @model.media_type_manifest,
    @codec.encode_manifest({ ..manifest, layers: [bad_layer], }),
  )
  source.set_index(@codec.encode_index({ ..root, manifests: [changed], }))
  let rejected = try {
    ignore(
      @registry.assemble_referrer_bundle(
        source,
        @digest.sha256(source.index()),
        changed.digest,
        [],
        [],
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
