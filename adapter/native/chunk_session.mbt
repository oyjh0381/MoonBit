///|
pub(all) struct TransferProgress {
  digest : @model.Digest
  size : Int64
  received_chunks : Int32
  received_bytes : Int64
  missing : Array[Int32]
}

///|
pub fn TransferProgress::complete(self : TransferProgress) -> Bool {
  self.missing.is_empty()
}

///|
pub fn transfer_progress_json(progress : TransferProgress) -> String {
  "{\"digest\":\"" +
  progress.digest.to_string() +
  "\",\"size\":\"" +
  progress.size.to_string() +
  "\",\"received_chunks\":" +
  progress.received_chunks.to_string() +
  ",\"received_bytes\":\"" +
  progress.received_bytes.to_string() +
  "\",\"all_chunks_present\":" +
  progress.complete().to_string() +
  ",\"missing\":[" +
  progress.missing.map(i => i.to_string()).join(",") +
  "]}"
}

///|
async fn open_transfer_session(
  session : String,
  expected : @model.Digest,
) -> @transfer.PreparedTransfer {
  require_transfer_kind(session, Directory)
  require_transfer_kind(join_path(session, "chunks"), Directory)
  load_chunk_plan(join_path(session, "plan.json"), expected)
}

///|
/// An immutable plan snapshot for a serialized long-lived host. Filesystem
/// contents are still revalidated for every read; no completion cache is trusted.
pub struct TransferSession {
  priv path : String
  priv plan : @transfer.PreparedTransfer
}

///|
pub async fn TransferSession::open(
  path : String,
  expected : @model.Digest,
) -> TransferSession {
  { path, plan: open_transfer_session(path, expected), }
}

///|
pub fn TransferSession::plan(
  self : TransferSession,
) -> @transfer.PreparedTransfer {
  self.plan
}

///|
pub async fn TransferSession::batch(
  self : TransferSession,
  max_chunks : Int32,
  max_bytes : Int64,
) -> @transfer.TransferBatch {
  // Validate host budgets before rehashing potentially large received content.
  ignore(self.plan.batch([], max_chunks~, max_bytes~))
  let progress = self.progress()
  self.plan.batch(progress.missing, max_chunks~, max_bytes~)
}

///|
fn chunk_path(session : String, index : Int32) -> String {
  join_path(session, "chunks/" + index.to_string())
}

///|
/// Persist immutable metadata. Completion is rediscovered from verified files,
/// never accepted from a stored bitmap. Caller owns trusted, quiescent parent
/// directories and serializes all access to a session and its output paths.
pub async fn start_transfer(
  plan_path : String,
  expected : @model.Digest,
  session : String,
) -> Unit {
  if session.is_empty() {
    raise @model.InvalidArgument("transfer session path must not be empty")
  }
  let plan = load_chunk_plan(plan_path, expected)
  let staging = session + ".moonoci-staging"
  if @fs.exists(session) || @fs.exists(staging) {
    raise @model.IoFailure(
      "transfer session or staging directory already exists",
    )
  }
  // Leave failed staging for inspection; do not recursively delete caller paths.
  @fs.mkdir(staging, permission=0o700) catch {
    error =>
      raise @model.IoFailure(
        "cannot create transfer staging directory: \{error}",
      )
  }
  @fs.mkdir(join_path(staging, "chunks"), permission=0o700) catch {
    error =>
      raise @model.IoFailure("cannot create transfer chunk directory: \{error}")
  }
  @fs.write_file(
    join_path(staging, "plan.json"),
    @transfer.encode_plan(plan),
    create_mode=CreateNew,
    sync=Full,
  ) catch {
    error => raise @model.IoFailure("cannot persist transfer plan: \{error}")
  }
  @fs.rename(staging, session, replace=false) catch {
    error => raise @model.IoFailure("cannot commit transfer session: \{error}")
  }
}

///|
/// Idempotent verified arrivals; existing chunk files are never replaced.
pub async fn receive_transfer_chunk(
  session : String,
  expected : @model.Digest,
  index : Int32,
  input : String,
) -> Unit {
  TransferSession::open(session, expected).receive(index, input)
}

///|
/// Reuse a prepared plan: O(chunk bytes), without reparsing K digest records.
pub async fn TransferSession::receive(
  self : TransferSession,
  index : Int32,
  input : String,
) -> Unit {
  let plan = self.plan
  let session = self.path
  let spec = plan.chunk(index)
  require_transfer_kind(input, Regular)
  let bytes = read_bounded_file(input, spec.size)
  plan.verify_chunk(index, bytes)
  let destination = chunk_path(session, index)
  if @fs.exists(destination) {
    require_transfer_kind(destination, Regular)
    plan.verify_chunk(index, read_bounded_file(destination, spec.size))
    return
  }
  let pending = destination + ".pending"
  @fs.write_file(pending, bytes, create_mode=CreateNew, sync=Full) catch {
    error => raise @model.IoFailure("cannot persist incoming chunk: \{error}")
  }
  @fs.rename(pending, destination, replace=false) catch {
    error => raise @model.IoFailure("cannot commit incoming chunk: \{error}")
  }
}

///|
/// O(K + received bytes) restart verification. all_chunks_present is not a
/// whole-content validity claim: finish_transfer remains mandatory.
pub async fn transfer_progress(
  session : String,
  expected : @model.Digest,
) -> TransferProgress {
  TransferSession::open(session, expected).progress()
}

///|
pub async fn TransferSession::progress(
  self : TransferSession,
) -> TransferProgress {
  let plan = self.plan
  let session = self.path
  let missing = []
  let mut received_bytes = 0L
  let mut received_chunks = 0
  for index in 0..<plan.chunk_count() {
    let path = chunk_path(session, index)
    if !@fs.exists(path) {
      missing.push(index)
      continue
    }
    require_transfer_kind(path, Regular)
    let spec = plan.chunk(index)
    plan.verify_chunk(index, read_bounded_file(path, spec.size))
    received_bytes += spec.size.to_int64()
    received_chunks += 1
  }
  {
    digest: plan.digest(),
    size: plan.size(),
    received_chunks,
    received_bytes,
    missing,
  }
}

///|
async fn assemble_transfer(
  session : String,
  plan : @transfer.PreparedTransfer,
  output : @fs.File,
) -> Unit {
  let verifier = @transfer.TransferVerifier::new(plan)
  for index in 0..<plan.chunk_count() {
    let path = chunk_path(session, index)
    if !@fs.exists(path) {
      raise @model.SizeMismatch("cannot finish: missing transfer chunk")
    }
    require_transfer_kind(path, Regular)
    let spec = plan.chunk(index)
    let bytes = read_bounded_file(path, spec.size)
    verifier.accept(index, bytes)
    output.write_at(bytes, position=spec.offset) catch {
      error => raise @model.IoFailure("cannot assemble transfer: \{error}")
    }
  }
  ignore(verifier.finish())
  output.sync() catch {
    error => raise @model.IoFailure("cannot sync completed transfer: \{error}")
  }
}

///|
/// Stream to a fresh staging file; publish only after whole-content verification.
pub async fn finish_transfer(
  session : String,
  expected : @model.Digest,
  destination : String,
) -> Unit {
  TransferSession::open(session, expected).finish(destination)
}

///|
pub async fn TransferSession::finish(
  self : TransferSession,
  destination : String,
) -> Unit {
  if destination.is_empty() {
    raise @model.InvalidArgument("transfer output path must not be empty")
  }
  let plan = self.plan
  let session = self.path
  let staging = destination + ".moonoci-partial"
  if @fs.exists(destination) || @fs.exists(staging) {
    raise @model.IoFailure("transfer output or partial file already exists")
  }
  let output = @fs.open(staging, mode=WriteOnly, create_mode=CreateNew) catch {
    error => raise @model.IoFailure("cannot create transfer output: \{error}")
  }
  {
    errdefer {
      output.close()
      // This exact file was created exclusively by this invocation.
      @fs.remove(staging) catch {
        _ => ()
      }
    }
    assemble_transfer(session, plan, output)
    output.close()
  }
  @fs.rename(staging, destination, replace=false) catch {
    error =>
      raise @model.IoFailure("cannot publish completed transfer: \{error}")
  }
}
