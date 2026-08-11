///|
fn main {
  run() catch {
    error => abort("single-layer example failed: \{error}")
  }
}

///|
fn run() -> Unit raise {
  let request = @builder.default_single_layer_request([
    @archive.TarEntry::directory("app"),
    @archive.TarEntry::file("app/message.txt", b"Hello from MoonOCI!\n"),
  ])
  let image = @builder.build_single_layer(request)
  let verification = @builder.verify_memory(image.layout)
  println("manifest: " + image.report.manifest.digest.to_string())
  println("valid: " + verification.is_valid().to_string())
}
