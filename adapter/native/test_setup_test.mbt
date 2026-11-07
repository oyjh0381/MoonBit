///|
// A workspace member can run from a clean module directory while compiler
// output lives at the workspace root. Fixture parents must exist independently
// of test ordering and concurrent test executables.
async fn ensure_test_build_root() -> Unit {
  @fs.mkdir("_build") catch {
    error =>
      if @fs.kind("_build", follow_symlink=false) != Directory {
        raise error
      }
  }
}
