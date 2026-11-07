///|
pub(all) struct ReferrerBundle {
  layout : @layout.MemoryLayout
  receipt : String
}

///|
/// Assemble a fresh offline bundle from independently fetched closures. Keep
/// the original source index as exact nested content instead of rewriting it.
/// Every advertised subject/type/annotation is checked against fetched metadata.
/// This verifies association and bytes, not document semantics or signatures.
pub fn assemble_referrer_bundle(
  source : @layout.MemoryLayout,
  source_pin : @model.Digest,
  subject : @model.Digest,
  advertisements : Array[@artifacts.ReferrerAdvertisement],
  fetched : Array[@layout.MemoryLayout],
  limits~ : PullLimits = PullLimits::default(),
) -> ReferrerBundle raise @model.MoonOciError {
  limits.validate()
  if advertisements.length() != fetched.length() ||
    advertisements.length() > 4096 {
    raise @model.InvalidArgument(
      "referrer bundle needs one bounded fetched closure per advertisement",
    )
  }
  if source.index().length() > limits.max_metadata_bytes {
    raise @model.ResourceLimitExceeded(
      "bundle source index exceeds metadata quota",
    )
  }
  if @digest.sha256(source.index()) != source_pin {
    raise @model.DigestMismatch("bundle source index does not match caller pin")
  }
  let graph_limits : @graph.WalkLimits = {
    max_depth: limits.max_depth,
    max_visits: limits.max_visits,
    max_metadata_bytes: limits.max_total_bytes,
  }
  let subject_descriptor = @artifacts.resolve_subject(
    source,
    subject,
    limits=graph_limits,
  )
  let result = @layout.MemoryLayout::new()
  let seen : Map[String, Bool] = Map([])
  let roots = []
  let mut total = 0L
  let mut visits = 0
  let sources = [source] + fetched
  for part in sources {
    @codec.validate_layout_marker(part.marker())
    if part.blob_count() > limits.max_visits - visits {
      raise @model.ResourceLimitExceeded(
        "bundle physical record visit quota exceeded",
      )
    }
    let part_seen : Map[String, Bool] = Map([])
    for record in part.blob_records() {
      visits += 1
      let descriptor = record.descriptor()
      let key = descriptor.digest.to_string()
      if part_seen.contains(key) {
        raise @model.InvalidOci("duplicate physical record in bundle input")
      }
      part_seen[key] = true
      if record.data().length() > limits.max_blob_bytes {
        raise @model.ResourceLimitExceeded(
          "bundle input content exceeds object byte quota",
        )
      }
      let raw = part.require_blob(descriptor)
      if !seen.contains(key) {
        if seen.length() == limits.max_objects ||
          raw.length().to_int64() > limits.max_total_bytes - total {
          raise @model.ResourceLimitExceeded(
            "bundle aggregate object/byte quota exceeded",
          )
        }
        ignore(result.put_blob(descriptor.media_type, raw))
        total += raw.length().to_int64()
        seen[key] = true
      }
    }
  }
  if advertisements.is_empty() {
    result.set_index(source.index())
  } else {
    let key = source_pin.to_string()
    if !seen.contains(key) {
      if seen.length() == limits.max_objects ||
        source.index().length().to_int64() > limits.max_total_bytes - total {
        raise @model.ResourceLimitExceeded(
          "bundle original index exceeds aggregate quota",
        )
      }
      total += source.index().length().to_int64()
      seen[key] = true
    }
    roots.push(result.put_blob(@model.media_type_index, source.index()))
    let advertised : Map[String, Bool] = Map([])
    for index, advertisement in advertisements {
      let descriptor = advertisement.descriptor
      let key = descriptor.digest.to_string()
      if advertised.contains(key) {
        raise @model.InvalidArgument("duplicate referrer in bundle request")
      }
      advertised[key] = true
      if fetched[index].index().length() > limits.max_metadata_bytes {
        raise @model.ResourceLimitExceeded(
          "fetched referrer index exceeds metadata quota",
        )
      }
      let root_bytes = fetched[index].index()
      let wrapper = @codec.decode_index(root_bytes)
      if wrapper.schema_version != 2 ||
        wrapper.media_type != @model.media_type_index {
        raise @model.InvalidOci("fetched referrer has invalid root index")
      }
      if descriptor.media_type == @model.media_type_index {
        if @digest.sha256(root_bytes) != descriptor.digest ||
          root_bytes.length().to_int64() != descriptor.size {
          raise @model.InvalidOci(
            "fetched index disagrees with referrer advertisement",
          )
        }
        if !seen.contains(key) {
          if seen.length() == limits.max_objects ||
            root_bytes.length().to_int64() > limits.max_total_bytes - total {
            raise @model.ResourceLimitExceeded(
              "referrer index exceeds bundle aggregate quota",
            )
          }
          total += root_bytes.length().to_int64()
          seen[key] = true
        }
        ignore(result.put_blob(descriptor.media_type, root_bytes))
      } else {
        if descriptor.media_type != @model.media_type_manifest ||
          wrapper.manifests.length() != 1 {
          raise @model.InvalidOci(
            "fetched manifest referrer must have one root descriptor",
          )
        }
        let actual = wrapper.manifests[0]
        if actual.digest != descriptor.digest ||
          actual.media_type != descriptor.media_type ||
          actual.size != descriptor.size {
          raise @model.InvalidOci(
            "fetched root disagrees with referrer advertisement",
          )
        }
      }
      let fields = match
        @codec.parse_json_document(result.require_blob(descriptor)) {
        Object(fields) => fields
        _ => raise @model.InvalidOci("referrer metadata must be an object")
      }
      let link = match fields.get("subject") {
        Some(value) => @codec.decode_descriptor(value)
        None => raise @model.InvalidOci("fetched referrer has no subject")
      }
      if link.digest != subject ||
        link.media_type != subject_descriptor.media_type ||
        link.size != subject_descriptor.size {
        raise @model.InvalidOci(
          "fetched referrer subject disagrees with local subject",
        )
      }
      roots.push(descriptor)
    }
    result.set_index(
      @codec.encode_index({
        schema_version: 2,
        media_type: @model.media_type_index,
        manifests: roots,
        annotations: [],
      }),
    )
    if result.index().length() > limits.max_metadata_bytes {
      raise @model.ResourceLimitExceeded(
        "bundle output index exceeds metadata quota",
      )
    }
    let association = @artifacts.verify_referrer_page(
      result, subject, advertisements,
    )
    if !association.valid {
      raise @model.InvalidOci(
        "fetched referrers disagree with advertised subject/type/annotations",
      )
    }
  }
  let verified = @artifacts.verify_store(
    result,
    graph_limits~,
    max_total_payload_bytes=limits.max_total_bytes,
  )
  if !verified.valid || !verified.complete {
    raise @model.InvalidOci(
      "assembled referrer bundle fails supported store verification",
    )
  }
  let receipt : Json = {
    "schema": Json::string("moonoci.referrer-bundle.v1"),
    "source_index": Json::string(source_pin.to_string()),
    "output_index": Json::string(@digest.sha256(result.index()).to_string()),
    "subject": Json::string(subject.to_string()),
    "referrers": Json::array(
      advertisements.map(item => {
        Json::string(item.descriptor.digest.to_string())
      }),
    ),
    "content_objects": Json::number(seen.length().to_double()),
    "content_bytes": Json::string(total.to_string()),
    "associations_verified": Json::boolean(true),
    "signatures_verified": Json::boolean(false),
  }
  { layout: result, receipt: receipt.stringify(), }
}
