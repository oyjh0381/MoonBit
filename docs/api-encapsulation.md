# Validated state is private

In the unreleased 0.2.0 source, layout internals, SHA-256 state, prepared chunk
plans/verifiers, Native session fields and content catalog internals are now
explicitly `priv`. MoonBit `pub struct` alone exposes readable fields; returning
an Array or Map through such a field permits outside mutation of that container.
Copying caller arrays at construction is insufficient if internal arrays escape.

This defect was reproduced from a black-box transfer test: after constructing a
valid prepared plan, external code changed `plan.chunks[0]`, and its next chunk
observation changed. After applying `priv`, that exact access was rejected by
MoonBit 0.10.16 with compiler error 4091 (no exposed `chunks` field). The temporary
negative compilation fixture was then removed from the passing test suite.

Use `PreparedTransfer.chunk/verify_chunk`, `TransferVerifier.accept/finish`,
`TransferSession` methods, `MemoryLayout` methods and `ContentCatalog` methods.
Catalog snapshots return a separate mutable layout wrapper over immutable Bytes.
Tests also mutate original constructor arrays and detached snapshots to ensure
that those documented interfaces do not mutate validated internal membership.

This is an intentional source-compatibility change for code that read internal
fields directly. Documented method-based consumers keep their interfaces. Raw
transport/configuration records such as ChunkPlan and ChunkSpec remain public:
they carry caller-owned inputs or observations, not trusted validator state.
The native/path and content-verification limits remain unchanged; field privacy
does not make untrusted filesystem parents safe or supply signature identity.
