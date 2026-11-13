///|
/// Final filesystem metadata tied to the exact contributing layer. A content
/// digest is present only for regular files; symlinks are never followed.
pub(all) struct FileEvidence {
  entry : @model.RootfsEntry
  layer_digest : @model.Digest
  content_digest : @model.Digest?
  uid : Int32
  gid : Int32
  mtime : Int64
}

///|
/// Observe one root manifest after graph validation. This does not extract files
/// or infer executable behavior. Callers select a platform explicitly upstream.
pub fn inventory_from_manifest(
  source : @layout.MemoryLayout,
  descriptor : @model.Descriptor,
) -> Array[FileEvidence] raise @model.MoonOciError {
  let manifest = require_root_manifest(source, descriptor)
  let rootfs = RootfsNode::empty()
  for layer_index, layer in manifest.layers {
    let interpretation = interpret_layer_blob(
      layer.media_type,
      source.require_blob(layer),
    )
    rootfs.apply(
      archived_rootfs_transitions(interpretation.entries),
      layer_index,
      evidence_layer=layer.digest,
    )
  }
  let evidence = rootfs.collect(node => node.evidence)
  evidence.sort_by((a, b) => @pathing.compare_utf8(a.entry.path, b.entry.path))
  evidence
}
