///|
fn main {
  run() catch {
    error => abort("reproducible example failed: \{error}")
  }
}

///|
fn run() -> Unit raise {
  let request = @builder.default_single_layer_request([
    @archive.TarEntry::file("b.txt", b"second"),
    @archive.TarEntry::file("a.txt", b"first"),
  ])
  let first = @builder.build_single_layer(request)
  let second = @builder.build_single_layer(request)
  if first.layout != second.layout {
    abort("identical declared inputs produced different layouts")
  }
  println("reproducible: " + first.report.manifest.digest.to_string())
}
