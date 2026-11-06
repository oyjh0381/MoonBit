///|
pub fn inventory_json(inventory : Array[@builder.FileEvidence]) -> String {
  let entries : Array[Json] = inventory.map(item => {
    "path": Json::string(item.entry.path),
    "kind": Json::string(item.entry.kind),
    "mode": Json::number(item.entry.mode.to_double()),
    "uid": Json::number(item.uid.to_double()),
    "gid": Json::number(item.gid.to_double()),
    "mtime": Json::string(item.mtime.to_string()),
    "bytes": Json::string(item.entry.size.to_string()),
    "layer_index": Json::number(item.entry.layer_index.to_double()),
    "layer_digest": Json::string(item.layer_digest.to_string()),
    "content_digest": match item.content_digest {
      Some(d) => Json::string(d.to_string())
      None => Json::null()
    },
    "link_target": match item.entry.link_target {
      Some(path) => Json::string(path)
      None => Json::null()
    },
  })
  let result : Json = {
    "schema": "moonoci.file-inventory.v1",
    "entries": Json::array(entries),
  }
  result.stringify()
}
