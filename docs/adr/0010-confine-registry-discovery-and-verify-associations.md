# ADR-0010: Confine Registry discovery and verify attachment associations

Status: accepted for unreleased 0.2.0.

## Context

An offline builder needs a usable ingestion boundary for releases and their
supply-chain attachments. A server-provided tag digest is not an independent
release pin. Referrers pages are mutable advertisements: transport authentication
alone cannot establish actual subject/type metadata, completeness or signatures.

## Decision

Keep portable parsing, graph acceptance, pagination and bundle assembly separate
from Native HTTP/TLS. Require a caller root pin and use new-copy publication only
after supported-profile semantic validation. Default to system HTTPS trust;
private CA replacement retains chain/name checks. Plain HTTP and cross-origin
realms/CDNs require explicit opt-in; never forward Registry Authorization to them.

Bound pagination to the original origin and exact subject endpoint. Budget all
advertisements, filter locally and refuse conflicting overlaps, loops and changed
filters. Treat exhaustion only as the end of the received Link chain. Fetch each
advertised root by digest and verify actual subject digest/media type/size,
artifact type, annotations, payload bytes and supported image/store semantics.

Wrap original source metadata as exact nested content. Bind an unsigned receipt
to input/output identities, retain original subject identities and do not imply
SBOM semantics or signature verification from media-type labels. Share transport
request/auth/time and accepted content entity budgets across bundle phases; keep
listing budgets distinct. Reuse verified content, not stale discovery results.

## Consequences

The caller controls release trust, required-type policy, origin allowlists and
filesystem isolation. A malicious registry can omit attachments; a later policy
gate can require known types but cannot prove repository completeness. This
profile does not implement push, password login, referrers-tag fallback, recursive
discovery, arbitrary relative pagination or Docker media aliases. Accepted bytes
exclude failed reads and protocol overhead; cancellation is cooperative.

Windows loopback Registry/TLS fixtures and independent ORAS/layout consumers
provide executable evidence without a VM. Public Registry failures and unexecuted
Linux CI/runtime scripts must remain distinct from passing local results.
