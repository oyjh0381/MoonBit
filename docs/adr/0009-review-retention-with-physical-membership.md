# ADR-0009: Review retention with physical membership

Status: accepted for unreleased 0.2.0.

## Context

Flat image reachability does not retain incoming supply-chain attachments.
Following weak subjects automatically can pull unrelated releases or require
external content. An index pin alone cannot detect an orphan added after review.
Round-tripping modeled descriptors can also discard unknown extension fields.

## Decision

Validate all physical SHA-256 content and recognized metadata into an explicitly
private snapshot. Bind a store fingerprint to root, marker and sorted physical
digest/size pairs. Keep strong edges distinct from weak subject links; expose
closure/referrers/complete modes rather than one implicit retention rule.

Materialize new copies, with selected aliases and raw extension fields retained.
Preserve nested metadata/payload bytes and original subject identities. Preserve
number lexemes on root rewrites; do not claim RFC 8785 or signing semantics.

Bind review to output root, physical source, explicit roots, policy and exact
kept/discarded sets. Revalidate source membership when applying an old plan.
Native export uses bounded filesystem loading and a separate supported-profile
semantic check before staging output. Never delete source data as a side effect.

## Consequences

Unknown root formats, missing strong local content, duplicate physical records
and corrupt orphan data block this conservative profile. Arbitrary metadata
extensions/remote blob fetching remain outside graph interpretation. A content
plan can exist for semantically invalid image data, so Native export must not
skip semantic verification. Caller-selected retention roots and future physical
deletion transactions remain host responsibilities.

Stored membership validation adds full-source hashing and IO. The immutable
snapshot shares immutable byte values but hides mutable arrays/maps explicitly.
Direct internal struct field access is intentionally incompatible; method-based
consumers continue to work. Filesystem parents must remain trusted and quiescent.

Literal independent fixture closures, exact unsigned pins and ORAS reads test
interoperability. Synthetic workload measurements do not establish production
SLOs, peak RSS bounds, Registry GC equivalence or Linux runtime success locally.
