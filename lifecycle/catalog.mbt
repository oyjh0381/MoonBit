///|
pub(all) struct CatalogLimits {
  max_blobs : Int32
  max_edges : Int32
  max_depth : Int32
  max_stored_bytes : Int64
  max_metadata_bytes : Int64
}

///|
pub fn CatalogLimits::default() -> CatalogLimits {
  {
    max_blobs: 65536,
    max_edges: 262144,
    max_depth: 64,
    max_stored_bytes: 1073741824L,
    max_metadata_bytes: 134217728L,
  }
}

///|
pub fn CatalogLimits::validate(
  self : CatalogLimits,
) -> Unit raise @model.MoonOciError {
  if self.max_blobs < 1 ||
    self.max_blobs > 65536 ||
    self.max_edges < 1 ||
    self.max_edges > 1000000 ||
    self.max_depth < 1 ||
    self.max_depth > 128 ||
    self.max_stored_bytes < 1L ||
    self.max_stored_bytes > 8589934592L ||
    self.max_metadata_bytes < 1L ||
    self.max_metadata_bytes > 536870912L {
    raise @model.InvalidArgument("invalid content catalog resource limits")
  }
}

///|
priv struct ContentNode {
  descriptor : @model.Descriptor
  advertisement : Json
  children : Array[@model.Descriptor]
  subject : @model.Descriptor?
  kind : String
  height : Int32
}

///|
/// Verified bytes and bounded metadata topology. Layer/DiffID semantics,
/// signature identity and artifact document semantics require separate checks.
pub struct ContentCatalog {
  priv marker : Bytes
  priv index : Bytes
  priv index_pin : @model.Digest
  priv store_pin : @model.Digest
  priv records : Map[String, Bytes]
  priv physical : Array[@model.Descriptor]
  priv nodes : Map[String, ContentNode]
  priv root_values : Array[Json]
  priv stored_bytes : Int64
}

///|
priv struct CatalogState {
  records : Map[String, Bytes]
  nodes : Map[String, ContentNode]
  active : Map[String, Bool]
  limits : CatalogLimits
  mut edges : Int32
  mut metadata_bytes : Int64
}

///|
fn descriptor_content(
  state : CatalogState,
  descriptor : @model.Descriptor,
) -> Bytes raise @model.MoonOciError {
  ignore(@model.Digest::parse(descriptor.digest.to_string()))
  state.edges += 1
  if state.edges > state.limits.max_edges {
    raise @model.ResourceLimitExceeded("catalog descriptor edge quota exceeded")
  }
  let bytes = match state.records.get(descriptor.digest.to_string()) {
    Some(data) => data
    None =>
      raise @model.InvalidOci(
        "missing strong content: " + descriptor.digest.to_string(),
      )
  }
  if descriptor.size < 0L || descriptor.size != bytes.length().to_int64() {
    raise @model.SizeMismatch(
      "catalog descriptor size disagrees with verified content",
    )
  }
  bytes
}

///|
fn metadata_node(
  state : CatalogState,
  advertisement : Json,
  depth : Int32,
) -> Int32 raise @model.MoonOciError {
  let descriptor = @codec.decode_descriptor(advertisement)
  let bytes = descriptor_content(state, descriptor)
  let key = descriptor.digest.to_string()
  if depth > state.limits.max_depth {
    raise @model.ResourceLimitExceeded("catalog metadata depth quota exceeded")
  }
  let kind = if descriptor.media_type == @model.media_type_index {
    "index"
  } else if descriptor.media_type == @model.media_type_manifest {
    "manifest"
  } else {
    raise @model.Unsupported(
      "catalog cannot infer references for an unknown root media type",
    )
  }
  if state.active.get(key).unwrap_or(false) {
    raise @model.InvalidOci("cyclic catalog metadata reference")
  }
  if state.nodes.get(key) is Some(node) {
    if node.kind != kind {
      raise @model.InvalidOci("one digest has conflicting metadata roles")
    }
    if node.height > state.limits.max_depth - depth {
      raise @model.ResourceLimitExceeded(
        "repeated subtree exceeds metadata depth quota",
      )
    }
    return node.height
  }
  if bytes.length().to_int64() >
    state.limits.max_metadata_bytes - state.metadata_bytes {
    raise @model.ResourceLimitExceeded("catalog metadata byte quota exceeded")
  }
  state.metadata_bytes += bytes.length().to_int64()
  state.active[key] = true
  let fields = match
    @codec.parse_json_document(bytes, preserve_number_repr=true) {
    Object(fields) => fields
    _ => raise @model.InvalidOci("catalog metadata must be an object")
  }
  let mut height = 0
  let children = if kind == "index" {
    let index = @codec.decode_index(bytes)
    if index.schema_version != 2 || index.media_type != @model.media_type_index {
      raise @model.InvalidOci("invalid catalog index schema/media type")
    }
    let values = match fields.get("manifests") {
      Some(Array(values)) => values
      _ => raise @model.InvalidOci("index manifests must be an array")
    }
    for value in values {
      let child_height = metadata_node(state, value, depth + 1) + 1
      if child_height > height {
        height = child_height
      }
    }
    index.manifests
  } else {
    let manifest = @codec.decode_manifest(bytes)
    if manifest.schema_version != 2 ||
      manifest.media_type != @model.media_type_manifest {
      raise @model.InvalidOci("invalid catalog manifest schema/media type")
    }
    let children = [manifest.config] + manifest.layers
    for child in children {
      ignore(descriptor_content(state, child))
    }
    children
  }
  let subject = match fields.get("subject") {
    Some(value) => {
      let subject = @codec.decode_descriptor(value)
      ignore(@model.Digest::parse(subject.digest.to_string()))
      if subject.size < 0L {
        raise @model.SizeMismatch("negative subject size")
      }
      if state.records.contains(subject.digest.to_string()) {
        let child_height = metadata_node(state, value, depth + 1) + 1
        if child_height > height {
          height = child_height
        }
      }
      Some(subject)
    }
    None => None
  }
  state.nodes[key] = {
    descriptor,
    advertisement,
    children,
    subject,
    kind,
    height,
  }
  state.active[key] = false
  height
}

///|
/// Validate physical membership, SHA-256 and sizes before interpreting topology.
/// Missing weak subjects are permitted. Locally present subjects must resolve
/// as known metadata. Unknown advertised roots fail this conservative profile.
pub fn catalog(
  source : @layout.MemoryLayout,
  expected_index : @model.Digest,
  limits~ : CatalogLimits = CatalogLimits::default(),
) -> ContentCatalog raise @model.MoonOciError {
  limits.validate()
  ignore(@model.Digest::parse(expected_index.to_string()))
  if @digest.sha256(source.index()) != expected_index {
    raise @model.DigestMismatch("catalog source index pin mismatch")
  }
  @codec.validate_layout_marker(source.marker())
  if source.index().length().to_int64() > limits.max_metadata_bytes ||
    source.blob_count() > limits.max_blobs {
    raise @model.ResourceLimitExceeded(
      "catalog root metadata/blob count quota exceeded",
    )
  }
  let records : Map[String, Bytes] = Map([])
  let physical : Array[@model.Descriptor] = []
  let mut stored_bytes = 0L
  for blob in source.blob_records() {
    let descriptor = blob.descriptor()
    ignore(@model.Digest::parse(descriptor.digest.to_string()))
    let key = descriptor.digest.to_string()
    if records.contains(key) {
      raise @model.InvalidOci("ambiguous duplicate physical content")
    }
    let bytes = blob.data()
    if bytes.length().to_int64() > limits.max_stored_bytes - stored_bytes {
      raise @model.ResourceLimitExceeded("catalog physical byte quota exceeded")
    }
    if descriptor.size != bytes.length().to_int64() {
      raise @model.SizeMismatch("physical blob size mismatch")
    }
    if @digest.sha256(bytes) != descriptor.digest {
      raise @model.DigestMismatch("physical blob SHA-256 mismatch")
    }
    stored_bytes += bytes.length().to_int64()
    records[key] = bytes
    physical.push({ ..descriptor, annotations: [], platform: None, })
  }
  physical.sort_by((a, b) => a.digest.to_string().compare(b.digest.to_string()))
  let index = @codec.decode_index(source.index())
  if index.schema_version != 2 || index.media_type != @model.media_type_index {
    raise @model.InvalidOci("catalog requires OCI index root")
  }
  let root_values = match
    @codec.parse_json_document(source.index(), preserve_number_repr=true) {
    Object(fields) =>
      match fields.get("manifests") {
        Some(Array(values)) => values
        _ => raise @model.InvalidOci("root manifests must be an array")
      }
    _ => raise @model.InvalidOci("root index must be an object")
  }
  let state : CatalogState = {
    records,
    nodes: Map([]),
    active: Map([]),
    limits,
    edges: 0,
    metadata_bytes: source.index().length().to_int64(),
  }
  for value in root_values {
    ignore(metadata_node(state, value, 1))
  }
  let lines = physical
    .map(d => d.digest.to_string() + " " + d.size.to_string())
    .join("\n")
  let store_pin = @digest.sha256(
    @utf8.encode(
      "moonoci.store.v1\n" +
      expected_index.to_string() +
      "\n" +
      @digest.sha256(source.marker()).to_string() +
      "\n" +
      lines +
      "\n",
    ),
  )
  {
    marker: source.marker(),
    index: source.index(),
    index_pin: expected_index,
    store_pin,
    records,
    physical,
    nodes: state.nodes,
    root_values,
    stored_bytes,
  }
}

///|
pub fn ContentCatalog::source_index(self : ContentCatalog) -> @model.Digest {
  self.index_pin
}

///|
/// Return a separate mutable layout wrapper over verified immutable byte data.
pub fn ContentCatalog::snapshot(self : ContentCatalog) -> @layout.MemoryLayout {
  @layout.MemoryLayout::from_untrusted_parts(
    self.marker,
    self.index,
    self.physical.map(d => {
      ({ ..d, annotations: [], }, self.records[d.digest.to_string()])
    }),
  )
}

///|
pub fn ContentCatalog::store_pin(self : ContentCatalog) -> @model.Digest {
  self.store_pin
}

///|
pub fn ContentCatalog::stored_bytes(self : ContentCatalog) -> Int64 {
  self.stored_bytes
}

///|
pub fn ContentCatalog::stored_blobs(self : ContentCatalog) -> Int32 {
  self.physical.length()
}

///|
pub fn ContentCatalog::metadata_count(self : ContentCatalog) -> Int32 {
  self.nodes.length()
}

///|
/// Inspect verified topology without returning mutable internal arrays/maps.
pub fn catalog_json(catalog : ContentCatalog) -> String {
  let keys = catalog.nodes.keys().collect()
  keys.sort()
  let metadata = keys.map(key => {
    let node = catalog.nodes[key]
    let value : Json = {
      "digest": Json::string(node.descriptor.digest.to_string()),
      "kind": Json::string(node.kind),
      "advertisement": node.advertisement,
      "children": Json::array(
        node.children.map(d => Json::string(d.digest.to_string())),
      ),
      "subject": match node.subject {
        Some(d) => Json::string(d.digest.to_string())
        None => Json::null()
      },
    }
    value
  })
  let value : Json = {
    "schema": Json::string("moonoci.catalog.v1"),
    "source_index": Json::string(catalog.index_pin.to_string()),
    "store_pin": Json::string(catalog.store_pin.to_string()),
    "stored_bytes": Json::string(catalog.stored_bytes.to_string()),
    "stored_blobs": Json::number(catalog.physical.length().to_double()),
    "roots": Json::array(catalog.root_values),
    "metadata": Json::array(metadata),
    "content_only": Json::boolean(true),
  }
  value.stringify()
}
