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
  if !verify_memory(source).is_valid() {
    raise @model.InvalidOci("file inventory requires a verified graph")
  }
  let index = @codec.decode_index(source.index())
  if !index.manifests.contains(descriptor) {
    raise @model.InvalidArgument(
      "inventory manifest must be a root index member",
    )
  }
  let manifest = @codec.decode_manifest(source.require_blob(descriptor))
  let config = @codec.decode_config(source.require_blob(manifest.config))
  if descriptor.platform is Some(platform) {
    if platform != config.platform {
      raise @model.InvalidOci("inventory platform disagrees with config")
    }
  }
  let mut rootfs : Array[@model.RootfsEntry] = []
  let mut evidence : Map[String, FileEvidence] = Map([])
  for layer_index, layer in manifest.layers {
    let interpretation = interpret_layer_blob(
      layer.media_type,
      source.require_blob(layer),
    )
    rootfs = apply_rootfs_transitions(
      rootfs,
      archived_rootfs_transitions(interpretation.entries),
      layer_index,
    )
    let entries : Map[String, @archive.TarEntry] = Map([])
    for entry in interpretation.entries {
      entries[entry.path] = entry
    }
    let next : Map[String, FileEvidence] = Map([])
    for final_entry in rootfs {
      if final_entry.layer_index == layer_index {
        let declared = match entries.get(final_entry.path) {
          Some(entry) => entry
          None =>
            raise @model.InvalidOci(
              "file provenance missing from contributing layer",
            )
        }
        next[final_entry.path] = {
          entry: final_entry,
          layer_digest: layer.digest,
          content_digest: if declared.kind == @archive.Regular {
            Some(@digest.sha256(declared.data))
          } else {
            None
          },
          uid: declared.uid,
          gid: declared.gid,
          mtime: declared.mtime,
        }
      } else {
        match evidence.get(final_entry.path) {
          Some(prior) => next[final_entry.path] = prior
          None => raise @model.InvalidOci("inherited file provenance missing")
        }
      }
    }
    evidence = next
  }
  rootfs.map(entry => evidence[entry.path])
}
