# Restartable, pinned delivery

The unreleased 0.2.0 `transfer` package handles content-independent chunk plans,
per-chunk checks, bounded missing-work batches and final whole-content checks.
The Native adapter persists restartable sessions. It works on Windows without a
daemon or VM and can carry OCI blobs, full archives or MoonOCI delta envelopes.
The transfer plan is a MoonOCI-specific format, not an OCI manifest, signature,
registry implementation or HTTP client.

## Executable consumer

Build Native Release and run:

```text
moon build --target native --release --deny-warn
python scripts/resume_chain.py --binary _build/native/release/build/cmd/moonoci/moonoci.exe
```

The consumer builds two real image layouts, creates their delta archive, splits
it into 16 KiB chunks and compares every digest/range against Python hashlib.
It receives a subset out of order, starts new CLI processes, rediscovers stored
chunks and transmits only missing work under byte/count budgets. After whole
verification it hydrates the delta and checks the resulting image independently.

The Windows run used a 336,896-byte archive and 21 chunks. It reused 114,688 bytes
after restart and received the remaining 222,208 bytes. These are fixture content
counts, not network or production bandwidth measurements. The test also covers
wrong release pins, idempotent arrivals, corrupt caches, malicious chunk metadata,
empty files, no-overwrite publication and recoverable pending-file states.

## Host integration

1. Producer calls `create_chunk_plan(SOURCE, CHUNK_BYTES, PLAN)` and
   `export_transfer_chunk` for independently verified source ranges. Planning
   reads a bounded chunk at a time and hashes both chunks and the entire source.
2. Host supplies an independently trusted whole-content SHA-256 pin, e.g. from
   its release metadata. Copying the pin from an untrusted plan proves nothing
   about the intended release. Plans can contain arbitrary per-chunk hashes.
3. Receiver calls `start_transfer(PLAN, PIN, SESSION)`, then opens a
   `TransferSession` once for a long-lived worker. `receive(index, file)` verifies
   incoming data and commits through a fresh `.pending` file. Duplicate valid
   arrivals are idempotent; existing content is never silently replaced.
4. `progress()` rechecks stored bytes. `batch(max_chunks, max_bytes)` selects an
   ascending prefix of missing chunks; insufficient byte budget fails rather
   than returning a misleading empty batch. Hosts may deliver that batch out of
   order. Scheduling does not implement concurrency control or network retries.
5. `finish(OUTPUT)` re-reads chunks in order, checks every chunk and the whole
   digest, syncs the output file, then renames it without replacing a destination.
   No output is published when metadata, data or the final whole pin disagrees.

The file-oriented commands expose the same flow:

```text
moonoci chunk-plan SOURCE CHUNK_BYTES OUTPUT_PLAN
moonoci chunk-export SOURCE PLAN EXPECTED_PIN INDEX OUTPUT_CHUNK
moonoci transfer-start PLAN EXPECTED_PIN SESSION
moonoci transfer-put SESSION EXPECTED_PIN INDEX CHUNK_FILE
moonoci transfer-status SESSION EXPECTED_PIN
moonoci transfer-batch SESSION EXPECTED_PIN MAX_CHUNKS MAX_BYTES
moonoci transfer-finish SESSION EXPECTED_PIN OUTPUT_FILE
```

`all_chunks_present` means that the local files pass per-chunk checks. It is
deliberately weaker than whole-content verification: a malicious plan can make
every chunk check pass while assembling the wrong content. Always call finish.

## Interrupted writes and recovery

```text
moonoci transfer-recover-chunk SESSION EXPECTED_PIN INDEX
moonoci transfer-recover-output SESSION EXPECTED_PIN OUTPUT_FILE
```

The first command validates an existing committed file, promotes a complete
verified `.pending` file, or reports missing. It refuses incomplete/corrupt files
and leaves them untouched. The second command verifies a complete existing
`OUTPUT_FILE.moonoci-partial` against chunk and whole hashes before publication.
It does not require chunk files if the partial output itself is complete.

Failed regular finish attempts close and remove only the exact partial file
created by that invocation. Abrupt process termination may leave it behind;
recovery refuses incomplete data. The operator can retain evidence and choose a
fresh session/output path. The library never recursively deletes session paths.
Session creation failures leave staging directories for inspection.

Tests construct the precise pending/partial on-disk states and restart separate
processes. They do not simulate real power loss, hard-kill every instruction
boundary, prove directory fsync durability or exercise concurrent writers.

## Cost, limits and boundaries

Let N be source bytes, C chunk size and K chunk count. Planning and final
verification cost O(N + K), with algorithmically retained content O(C + K).
Native reads hold one chunk, not a whole blob. This describes reachable working
data, not a process RSS guarantee; allocator/GC and filesystem caching also cost
memory. Other MoonOCI layout, tar and hydration APIs still use whole buffers.

A prepared `TransferSession` parses/validates K digest records once and receives
each new chunk in O(C) hashing/IO work. The file-oriented convenience functions
and separate CLI processes reopen metadata each time: K arrivals can incur
O(K²) metadata work. Use a long-lived session for large chunk counts. Progress
and batch intentionally rehash all received data, O(K + received bytes), so
polling on every packet can dominate throughput. Missing-work selection alone
uses an O(K) bitmap; final verification hashes all bytes again.

Hard limits are 8 GiB per content object, 65,536 chunks, 16 MiB per chunk and
8 MiB JSON plan metadata; hosts can lower content/count/chunk quotas. Empty
content has no chunks and must use SHA-256 of the empty string. Sizes/offsets use
Int64, and JSON sizes/offsets are decimal strings. Limits are logical content
budgets, not a complete heap/sandbox limit. A 32 MiB workload exercises the
65,536-chunk boundary and refuses the 65,537th chunk; 8 GiB content objects are
not yet tested. Disk use includes chunk copies, incoming files and a final output.

The host owns trusted parent directories, keeps source/session files quiescent
and serializes mutations. Individual inputs and chunk files reject symlinks,
but these path-based APIs do not provide descriptor-relative no-follow traversal,
hostile parent-directory isolation, file locks or race-free sandboxing. A session
handle retains its immutable prepared plan; reopening reloads and revalidates
metadata. Callers own transport, authorization, release trust and cleanup policy.

Use the workload script for explicit local measurements:

```text
python scripts/transfer_benchmark.py --binary _build/native/release/build/cmd/moonoci/moonoci.exe --size-mib 32 --runs 3
```

It reports end-to-end CLI wall time and metadata size for four chunk sizes,
checks all hashes independently, and records machine conditions under `_build`.
It measures neither peak memory nor comparative speedup. Linux CI runs the
consumer, while the separate Podman/Skopeo job remains the container-runtime
verification path; local Windows success does not imply Linux runtime success.
