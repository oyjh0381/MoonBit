///|
pub(all) struct FileChange {
  path : String
  kind : String
  before : @builder.FileEvidence?
  after : @builder.FileEvidence?
  content_changed : Bool
  metadata_changed : Bool
  link_changed : Bool
  type_changed : Bool
  source_changed : Bool
}

///|
pub(all) struct FileComparison {
  base_manifest : @model.Digest
  target_manifest : @model.Digest
  changes : Array[FileChange]
  added : Int32
  removed : Int32
  modified : Int32
  provenance_only : Int32
}

///|
/// Compare final content, not merely tar membership, size or layer digest.
/// Repacking identical files is ignored unless provenance reporting is requested.
pub fn compare_files(
  base : @layout.MemoryLayout,
  base_manifest : @model.Descriptor,
  target : @layout.MemoryLayout,
  target_manifest : @model.Descriptor,
  include_provenance~ : Bool = false,
) -> FileComparison raise @model.MoonOciError {
  let before : Map[String, @builder.FileEvidence] = Map([])
  let after : Map[String, @builder.FileEvidence] = Map([])
  let paths : Map[String, Bool] = Map([])
  for item in @builder.inventory_from_manifest(base, base_manifest) {
    before[item.entry.path] = item
    paths[item.entry.path] = true
  }
  for item in @builder.inventory_from_manifest(target, target_manifest) {
    after[item.entry.path] = item
    paths[item.entry.path] = true
  }
  let ordered = paths.keys().collect()
  ordered.sort_by((a, b) => @pathing.compare_utf8(a, b))
  let changes : Array[FileChange] = []
  let mut added = 0
  let mut removed = 0
  let mut modified = 0
  let mut provenance_only = 0
  for path in ordered {
    let old = before.get(path)
    let next = after.get(path)
    match (old, next) {
      (None, Some(_)) => {
        added += 1
        changes.push({
          path,
          kind: "added",
          before: old,
          after: next,
          content_changed: false,
          metadata_changed: false,
          link_changed: false,
          type_changed: false,
          source_changed: false,
        })
      }
      (Some(_), None) => {
        removed += 1
        changes.push({
          path,
          kind: "removed",
          before: old,
          after: next,
          content_changed: false,
          metadata_changed: false,
          link_changed: false,
          type_changed: false,
          source_changed: false,
        })
      }
      (Some(a), Some(b)) => {
        let content_changed = a.content_digest != b.content_digest
        let metadata_changed = a.entry.mode != b.entry.mode ||
          a.uid != b.uid ||
          a.gid != b.gid ||
          a.mtime != b.mtime
        let link_changed = a.entry.link_target != b.entry.link_target
        let type_changed = a.entry.kind != b.entry.kind
        let source_changed = a.layer_digest != b.layer_digest ||
          a.entry.layer_index != b.entry.layer_index
        let filesystem_changed = content_changed ||
          metadata_changed ||
          link_changed ||
          type_changed
        if filesystem_changed || (include_provenance && source_changed) {
          if filesystem_changed {
            modified += 1
          } else {
            provenance_only += 1
          }
          changes.push({
            path,
            kind: if filesystem_changed {
              "modified"
            } else {
              "provenance"
            },
            before: old,
            after: next,
            content_changed,
            metadata_changed,
            link_changed,
            type_changed,
            source_changed,
          })
        }
      }
      _ => ()
    }
  }
  {
    base_manifest: base_manifest.digest,
    target_manifest: target_manifest.digest,
    changes,
    added,
    removed,
    modified,
    provenance_only,
  }
}

///|
pub fn files_json(comparison : FileComparison) -> String {
  let changes : Array[Json] = comparison.changes.map(change => {
    "path": Json::string(change.path),
    "kind": Json::string(change.kind),
    "content_changed": Json::boolean(change.content_changed),
    "metadata_changed": Json::boolean(change.metadata_changed),
    "link_changed": Json::boolean(change.link_changed),
    "type_changed": Json::boolean(change.type_changed),
    "source_changed": Json::boolean(change.source_changed),
  })
  let result : Json = {
    "schema": "moonoci.file-comparison.v1",
    "base_manifest": Json::string(comparison.base_manifest.to_string()),
    "target_manifest": Json::string(comparison.target_manifest.to_string()),
    "added": Json::number(comparison.added.to_double()),
    "removed": Json::number(comparison.removed.to_double()),
    "modified": Json::number(comparison.modified.to_double()),
    "provenance_only": Json::number(comparison.provenance_only.to_double()),
    "changes": Json::array(changes),
  }
  result.stringify()
}
