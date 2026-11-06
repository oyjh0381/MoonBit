///|
pub(all) struct RetentionPolicy {
  include_referrers : Bool
  include_subjects : Bool
}

///|
pub fn RetentionPolicy::default() -> RetentionPolicy {
  { include_referrers: true, include_subjects: false, }
}

///|
/// A content-bound copy plan. No API deletes or mutates the source store.
pub struct RetentionPlan {
  priv catalog : ContentCatalog
  priv output_index : Bytes
  priv kept : Array[@model.Descriptor]
  priv discarded : Array[@model.Descriptor]
  priv selected : Array[@model.Digest]
  priv policy : RetentionPolicy
}

///|
priv struct RetentionState {
  catalog : ContentCatalog
  kept : Map[String, Bool]
  queued : Map[String, Bool]
  announced : Map[String, Bool]
  queue : Array[String]
  referrers : Map[String, Array[String]]
}

///|
fn retain_metadata(
  state : RetentionState,
  key : String,
  announce : Bool,
) -> Unit raise @model.MoonOciError {
  if !state.catalog.nodes.contains(key) {
    raise @model.InvalidArgument(
      "retention root/subject is not recognized local metadata: " + key,
    )
  }
  state.kept[key] = true
  if announce {
    state.announced[key] = true
  }
  if !state.queued.contains(key) {
    state.queued[key] = true
    state.queue.push(key)
  }
}

///|
/// Stable field ordering, preserving parsed scalar number spellings. This is
/// not RFC 8785 canonicalization and must not be used as a signature format.
fn stable_json(value : Json, depth : Int32) -> String raise @model.MoonOciError {
  if depth > 128 {
    raise @model.ResourceLimitExceeded("retained JSON nesting exceeds 128")
  }
  match value {
    Object(fields) => {
      let keys = fields.keys().collect()
      keys.sort_by((a, b) => @pathing.compare_utf8(a, b))
      "{" +
      keys
      .map(key => {
        Json::string(key).stringify() +
        ":" +
        stable_json(fields[key], depth + 1)
      })
      .join(",") +
      "}"
    }
    Array(values) =>
      "[" + values.map(item => stable_json(item, depth + 1)).join(",") + "]"
    _ => value.stringify()
  }
}

///|
/// Retain strong content closure plus explicit weak-link policy. Referencing
/// metadata already parsed through another root does not imply its payload
/// bytes are retained; every strong edge is visited when its owner is retained.
pub fn ContentCatalog::retain(
  self : ContentCatalog,
  roots : Array[@model.Digest],
  policy~ : RetentionPolicy = RetentionPolicy::default(),
) -> RetentionPlan raise @model.MoonOciError {
  if roots.is_empty() || roots.length() > self.nodes.length() {
    raise @model.InvalidArgument(
      "retention needs a nonempty bounded root selection",
    )
  }
  let incoming : Map[String, Array[String]] = Map([])
  for key, node in self.nodes {
    if node.subject is Some(subject) {
      let target = subject.digest.to_string()
      let values = incoming.get(target).unwrap_or([])
      values.push(key)
      incoming[target] = values
    }
  }
  for _, values in incoming {
    values.sort()
  }
  let state : RetentionState = {
    catalog: self,
    kept: Map([]),
    queued: Map([]),
    announced: Map([]),
    queue: [],
    referrers: incoming,
  }
  let selected : Map[String, Bool] = Map([])
  for digest in roots {
    ignore(@model.Digest::parse(digest.to_string()))
    let key = digest.to_string()
    if selected.contains(key) {
      raise @model.InvalidArgument("duplicate retention root")
    }
    selected[key] = true
    retain_metadata(state, key, true)
  }
  let mut cursor = 0
  while cursor < state.queue.length() {
    let key = state.queue[cursor]
    cursor += 1
    let node = self.nodes[key]
    for child in node.children {
      let child_key = child.digest.to_string()
      state.kept[child_key] = true
      if node.kind == "index" {
        retain_metadata(state, child_key, false)
      }
    }
    if policy.include_subjects {
      if node.subject is Some(subject) {
        retain_metadata(state, subject.digest.to_string(), true)
      }
    }
    if policy.include_referrers {
      for referrer in state.referrers.get(key).unwrap_or([]) {
        retain_metadata(state, referrer, true)
      }
    }
  }
  let values : Array[Json] = []
  let advertised : Map[String, Bool] = Map([])
  // Keep all aliases and extension fields of selected original root descriptors.
  for value in self.root_values {
    let key = @codec.decode_descriptor(value).digest.to_string()
    if state.announced.contains(key) {
      values.push(value)
      advertised[key] = true
    }
  }
  let keys = state.announced.keys().collect()
  keys.sort()
  for key in keys {
    if !advertised.contains(key) {
      values.push(self.nodes[key].advertisement)
    }
  }
  let output_index = if values.length() == self.root_values.length() &&
    self.root_values.all(value => {
      state.announced.contains(
        @codec.decode_descriptor(value).digest.to_string(),
      )
    }) {
    self.index
  } else {
    let fields = match
      @codec.parse_json_document(self.index, preserve_number_repr=true) {
      Object(fields) => fields
      _ => raise @model.InvalidOci("catalog root is not an index object")
    }
    fields["manifests"] = Json::array(values)
    let bytes = @utf8.encode(stable_json(Json::object(fields), 0))
    if bytes.length() > 16777216 {
      raise @model.ResourceLimitExceeded("retained root exceeds 16 MiB")
    }
    bytes
  }
  let kept = self.physical.filter(d => state.kept.contains(d.digest.to_string()))
  let discarded = self.physical.filter(d => {
    !state.kept.contains(d.digest.to_string())
  })
  let selected = roots.copy()
  selected.sort_by((a, b) => a.to_string().compare(b.to_string()))
  { catalog: self, output_index, kept, discarded, selected, policy, }
}

///|
pub fn RetentionPlan::materialize(self : RetentionPlan) -> @layout.MemoryLayout {
  @layout.MemoryLayout::from_untrusted_parts(
    self.catalog.marker,
    self.output_index,
    self.kept.map(d => {
      ({ ..d, annotations: [], }, self.catalog.records[d.digest.to_string()])
    }),
  )
}

///|
pub fn RetentionPlan::kept_blobs(self : RetentionPlan) -> Int32 {
  self.kept.length()
}

///|
pub fn RetentionPlan::discarded_blobs(self : RetentionPlan) -> Int32 {
  self.discarded.length()
}

///|
pub fn RetentionPlan::reclaimable_bytes(self : RetentionPlan) -> Int64 {
  let mut bytes = 0L
  for descriptor in self.discarded {
    bytes += descriptor.size
  }
  bytes
}

///|
pub fn retention_json(plan : RetentionPlan) -> String {
  let value : Json = {
    "schema": Json::string("moonoci.retention.v1"),
    "source_index": Json::string(plan.catalog.index_pin.to_string()),
    "source_store": Json::string(plan.catalog.store_pin.to_string()),
    "plan_pin": Json::string(plan.pin().to_string()),
    "output_index": Json::string(@digest.sha256(plan.output_index).to_string()),
    "selected": Json::array(plan.selected.map(d => Json::string(d.to_string()))),
    "include_referrers": Json::boolean(plan.policy.include_referrers),
    "include_subjects": Json::boolean(plan.policy.include_subjects),
    "kept": Json::array(plan.kept.map(d => Json::string(d.digest.to_string()))),
    "discarded": Json::array(
      plan.discarded.map(d => Json::string(d.digest.to_string())),
    ),
    "reclaimable_bytes": Json::string(plan.reclaimable_bytes().to_string()),
    "content_only": Json::boolean(true),
    "source_mutated": Json::boolean(false),
  }
  value.stringify()
}
