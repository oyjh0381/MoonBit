///|
/// A dependency order for a single registry publication. Blob endpoints and
/// manifest endpoints have separate membership even for identical bytes.
pub(all) struct UploadClosure {
  root : @model.Descriptor
  blobs : Array[@model.Descriptor]
  manifests : Array[@model.Descriptor]
}

///|
priv struct UploadTraversal {
  seen_blobs : Map[String, Bool]
  seen_manifests : Map[String, Bool]
  blobs : Array[@model.Descriptor]
  manifests : Array[@model.Descriptor]
}

///|
fn detached_descriptor(descriptor : @model.Descriptor) -> @model.Descriptor {
  { ..descriptor, annotations: descriptor.annotations.copy(), }
}

///|
fn collect_upload_dependencies(
  catalog : ContentCatalog,
  descriptor : @model.Descriptor,
  traversal : UploadTraversal,
) -> Unit {
  let key = descriptor.digest.to_string()
  if traversal.seen_manifests.contains(key) {
    return
  }
  traversal.seen_manifests[key] = true
  let node = catalog.nodes[key]
  for child in node.children {
    if node.kind == "index" {
      collect_upload_dependencies(catalog, child, traversal)
    } else {
      let child_key = child.digest.to_string()
      if !traversal.seen_blobs.contains(child_key) {
        traversal.seen_blobs[child_key] = true
        traversal.blobs.push(detached_descriptor(child))
      }
    }
  }
  traversal.manifests.push(detached_descriptor(descriptor))
}

///|
/// Order the verified strong closure of one named root for OCI Distribution.
/// Send the deduplicated Blobs first, then the manifests in the returned order.
/// Subject relationships are weak edges and are outside this closure.
pub fn ContentCatalog::upload_closure(
  self : ContentCatalog,
  name : String,
) -> UploadClosure raise @model.MoonOciError {
  let root = self.resolve_reference(name)
  let traversal : UploadTraversal = {
    seen_blobs: Map([]),
    seen_manifests: Map([]),
    blobs: [],
    manifests: [],
  }
  collect_upload_dependencies(self, root, traversal)
  { root, blobs: traversal.blobs, manifests: traversal.manifests, }
}
