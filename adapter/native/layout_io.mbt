///|
/// Load the files of an OCI Image Layout without trusting their descriptors.
pub async fn load_layout(source : String) -> @layout.MemoryLayout {
  let marker_path = join_path(source, "oci-layout")
  let index_path = join_path(source, "index.json")
  let blob_dir = join_path(source, "blobs/sha256")
  if !@fs.exists(marker_path) ||
    !@fs.exists(index_path) ||
    !@fs.exists(blob_dir) {
    raise @model.InvalidOci(
      "directory is missing required OCI Image Layout files",
    )
  }
  let marker = @fs.read_file(marker_path).binary()
  let index = @fs.read_file(index_path).binary()
  let blobs : Array[(@model.Descriptor, Bytes)] = []
  for
    name in @fs.readdir(
      blob_dir,
      include_hidden=false,
      include_special=false,
      sort=true,
    ) {
    let digest = @model.Digest::sha256(name)
    let path = join_path(blob_dir, name)
    if @fs.kind(path, follow_symlink=false) != Regular {
      raise @model.InvalidOci("Blob path must be a regular file: " + name)
    }
    let data = @fs.read_file(path).binary()
    blobs.push(
      (
        {
          media_type: "",
          digest,
          size: data.length().to_int64(),
          annotations: [],
          platform: None,
        },
        data,
      ),
    )
  }
  @layout.MemoryLayout::from_untrusted_parts(marker, index, blobs)
}

///|
/// Encode every layout file into one deterministic tar archive.
pub fn archive_layout_bytes(
  layout : @layout.MemoryLayout,
) -> Bytes raise @model.MoonOciError {
  let entries = [
    @archive.TarEntry::file("oci-layout", layout.marker()),
    @archive.TarEntry::file("index.json", layout.index()),
  ]
  for blob in layout.blob_records() {
    entries.push(
      @archive.TarEntry::file(blob.descriptor().digest.blob_path(), blob.data()),
    )
  }
  @archive.write_tar(entries)
}

///|
/// Load a layout and create a new deterministic tar file.
pub async fn archive_layout_file(source : String, destination : String) -> Unit {
  if @fs.exists(destination) {
    raise @model.IoFailure("archive destination already exists: " + destination)
  }
  let layout = load_layout(source)
  @fs.write_file(
    destination,
    archive_layout_bytes(layout),
    create_mode=CreateNew,
  )
}
