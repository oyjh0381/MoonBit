# ADR-0008: Verify restart state from content

Status: accepted for unreleased 0.2.0.

## Context

Offline image updates may arrive across interrupted file copies or host-managed
transports. Reusing an unchecked bitmap or serializing internal SHA-256 state
would let damaged checkpoints bypass content checks and would couple the wire
format to one hash implementation. Re-parsing a full plan for every arrival also
causes quadratic metadata work at high chunk counts.

## Decision

Keep a versioned bounded plan containing whole digest, size, fixed chunk size and
ordered chunk digests. Derive offsets and tail sizes, validate exact coverage and
copy mutable caller arrays into an opaque prepared snapshot. Use only SHA-256.
The host supplies the trusted whole-content pin separately from the plan.

Persist chunk files by numeric index under a host-owned session directory. Use
fresh pending files and no-replace renames. Rediscover restart progress by
checking actual file sizes and digests. A Native session handle reuses the
prepared plan but never caches file validity. Bounded missing batches represent
transport work only, with no protocol or concurrency management.

Finalization streams through both per-chunk and whole-content verification into
a new output. It publishes only after the whole pin matches. Verified complete
pending/partial states may be explicitly recovered; corrupt evidence is retained.
Do not recursively clean session directories or overwrite source/destination data.

## Consequences

- Chunk metadata can be untrusted without bypassing the final whole pin, but may
  still cause bounded failed work. A trusted pin has no built-in signer identity.
- Restart/progress checks deliberately spend linear hashing/IO work. Frequent
  status polling is costly. Long-lived hosts avoid repeated K-record parsing.
- Hash state is recreated from stored content; interrupted final assembly is
  reverified rather than resumed from an opaque serialized hash checkpoint.
- Source/session parents must be trusted and quiescent, and callers serialize
  mutations. These path APIs are not a hostile-directory sandbox or file-locking
  protocol. Syncing files does not prove crash/power-loss durability of directories.
- Tests exercise separate-process restarts and constructed interrupted states.
  They do not claim real power-loss coverage, a registry implementation, network
  performance, peak-process-memory bounds or completeness of all OCI runtimes.
