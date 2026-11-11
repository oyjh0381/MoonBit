# Read-only Registry consumer

The portable `registry` package validates origins, repository paths, pinned
responses, pull-only Bearer challenges, retries and bounded content graphs. The
Native `adapter/remote` package supplies HTTP/TLS, cancellation and time budgets.
`registry-pull` verifies the complete supported image/artifact graph before
creating a new destination. Existing destinations are never overwritten.

```text
moonoci registry-pull https://registry.example.org team/app release \
  sha256:<trusted-root> output --allow-realm https://auth.example.org
```

The root pin must come from the caller's trusted release workflow. A digest
advertised by an untrusted registry is not an independent trust source. This is
a read-only OCI Distribution profile, not a general Docker registry client.
SHA-256 and OCI index/manifest media types are supported; push, login/password
storage, Docker media aliases and signature verification are not implemented.

HTTPS uses system trust by default. Private PKI can use `--ca-file roots.pem`
(`RegistryOptions.ca_file`); this replaces system roots for the operation, and
certificate-chain and hostname checks remain mandatory. Trust applies to the
registry, explicitly permitted token realms and blob origins. There is no
skip-verification option and the OS trust store is never modified. Plain HTTP
requires `--allow-http`; HTTPS redirects cannot downgrade to HTTP.

Registry tokens can be supplied through `MOONOCI_REGISTRY_TOKEN`, never through
command-line arguments. Cross-origin realms and blob redirects require separate
explicit origin allowlists. Authorization is sent only to the original registry
and is never forwarded to the token endpoint or a blob CDN. Anonymous Bearer
exchange requests only `repository:<repository>:pull` even if a challenge asks
for wider privileges. Token values and signed redirect queries are not logged.

Body, graph, request, redirect, authentication, retry and cooperative time
budgets are separate. `--retries` and `--max-retry-delay-ms` bound retries for
network failures and selected transient statuses. A valid numeric Retry-After
above the allowed delay is refused rather than retried early. CPU validation is
not preempted by the async timeout. `--cache` rechecks cached content pins;
accepted network byte statistics exclude headers, token responses and retries.
`responses_complete` means fetched, whereas `complete` requires successful
semantic verification of the supported store profile.

## Verification without a local Linux VM

After building Native Release, Windows or Linux can execute:

```text
python scripts/setup_oras.py
python -m pip install cryptography==49.0.0
python scripts/registry_tls_chain.py --binary <moonoci>
python scripts/registry_chain.py --binary <moonoci> --oras <oras-1.3.6>
```

The HTTP fixture checks token scope, redirect credential isolation, corrupt
cache, malformed/interrupted responses, timeouts, retry bounds, artifact gates
and an independent ORAS copy. The HTTPS fixture generates ephemeral certificates
under ignored `_build`, checks custom-CA success, default distrust and wrong-name
rejection. No registry is uploaded to and no real credentials are needed.
`cryptography` is a development-only certificate fixture dependency.

These chains have been executed on Windows. Linux CI jobs are configured but
must be run on a remote runner before claiming Linux results. These tests verify
transport and layout consumption; Podman runtime execution remains a distinct
Linux verification step. A public Docker Hub attempt timed out locally and is
not counted as a passing public-registry or public-TLS result.

An independent public-image path uses ORAS 1.3.6 to fetch the pinned
linux/amd64 Alpine manifest from Docker Hub. MoonOCI verifies and projects the
downloaded layout. CPython independently checks the OCI descriptor hashes,
DiffID and every final inventory entry, including link metadata.

```text
python scripts/public_image_chain.py --binary <moonoci> --oras <oras-1.3.6>
python scripts/public_image_chain.py --binary <moonoci> --layout <downloaded-layout>
```

The initial ORAS fetch succeeded locally. A later fetch hit a TLS handshake
timeout, so the comparison can be replayed from the downloaded bytes and
reports that mode separately. This evidence covers public registry acquisition
with ORAS and offline MoonOCI consumption. The Linux runtime job remains separate.

## Referrer discovery profile

```text
moonoci registry-referrers https://registry.example.org team/app \
  sha256:<subject> --artifact-type application/spdx+json --max-pages 64
```

The Native `discover_referrers` API and CLI share pull transport credentials,
custom CA, origin isolation, retries, request quotas and total time budgets. The
JSON report explicitly marks `manifests_verified: false`; it carries actual
advertisements for subsequent digest-pinned fetching, not an admission decision.

`ReferrerSession` walks bounded OCI referrers pages. Each acceptance validates
headers, body length, OCI index shape, optional digest header, advertisements and
the next link before committing any state. Identical overlapping advertisements
are deduplicated; conflicting metadata for one digest is refused. All advertised
entries count toward the budget, including entries excluded by local filtering.

Link targets must be absolute or root-relative, remain on the same origin and
exact subject endpoint, and use only `last`, `n` and `artifactType` query names.
A missing type filter is restored; changing it is refused. Duplicate parameters,
contextual anchors, multiple next links, repeated URLs and unfinished pagination
at the configured page quota are errors. This intentionally bounded profile does
not support relative targets or arbitrary pagination extension parameters.

A completed session only proves exhaustion of the received Link chain. The
registry can omit attachments or change between pages. Listings are discovery
metadata, not signed evidence or a proof of repository completeness. Advertised
manifests must subsequently be fetched by digest and checked for actual subject,
type and annotations before a host relies on them.

`assemble_referrer_bundle` closes that boundary for supplied fetched layouts:
it checks the caller's source index pin, resolves the local metadata subject,
validates physical records and aggregate quotas, compares each fetched root with
its advertisement, and checks exact subject digest/media type/size plus actual
artifact type and annotations. A final supported-store semantic verification is
mandatory, including when the listing is empty. Wrong-subject, forged-type,
corrupt-payload and conflicting-root inputs do not produce a bundle.

Nonempty bundles wrap the original source index as exact nested content and add
verified referrer roots. Original metadata/extensions, subject identities and
payload bytes are retained; the output index gets a new digest. Empty bundles
preserve the original index bytes. The returned receipt binds input/output pins
and verified associations, with `signatures_verified: false`. Neither an SPDX
media type nor an in-toto media type implies semantic or cryptographic validity.

## Release with remotely discovered attachments

```text
moonoci registry-bundle https://registry.example.org team/app release \
  sha256:<trusted-root> sha256:<local-image-or-index-subject> offline-release \
  --allow-realm https://auth.example.org
moonoci artifact-gate offline-release sha256:<subject> application/spdx+json
```

`pull_with_referrers`/`registry-bundle` combine a pinned base pull, local subject
resolution, paginated discovery, digest-pinned closure pulls and verified bundle
assembly. Authentication and HTTP quotas, accepted content entity bytes and the
total cooperative timeout are shared across all these phases. Separate listing
byte/page/entry budgets remain active. Content already verified during the base
or preceding attachment pulls is reused; the optional external cache is only
consumed through per-content verification and is not mutated. Failed pulls or
associations do not publish any destination.

The accepted-content byte counter excludes listing pages, token responses,
headers and failed transport attempts. It is not a TCP traffic meter. Cache
reuse still performs live discovery; an old attachment listing is not implicitly
reused as current. Only immediate referrers of one explicit local subject are
discovered; fallback referrers tags and recursive attachment discovery are not
implemented. Unknown/absent advertised types must match actual metadata under
the strict association profile. Host policy decides which types are required.

The source pin in a bundle receipt identifies the verified local base index. A
manifest-root pull receives a generated OCI layout wrapper; the transport report
separately records the original trusted manifest digest. New nested wrappers
change the output index digest without changing original subjects or payloads.

## Operator budgets

All commands accept `--max-http-requests`, `--max-auth-requests` and
`--max-redirects`, alongside time/retry controls. Pull and bundle additionally
accept `--max-content-bytes`, `--max-blob-bytes`, `--max-metadata-bytes`,
`--max-objects`, `--max-visits` and `--max-depth`. Discovery and bundle accept
`--max-pages`, `--max-entries`, `--max-page-bytes` and `--max-listing-bytes`.
Byte values are decimal bytes, not MiB abbreviations. Invalid, overflowing or
out-of-profile values fail before any HTTP request.

Defaults: 4096 content objects, 16384 graph visits, depth 32, 16 MiB metadata,
64 MiB blobs, 512 MiB content; discovery 64 pages, 4096 advertisements, 1 MiB per
page and 16 MiB total listing bytes. Hard supported limits remain enforced by
`PullLimits.validate`, `DiscoveryLimits.validate` and `RegistryOptions.validate`;
increasing a caller budget cannot disable semantic decoder limits.

The native fixture tightens each content/graph/HTTP/auth/listing quota separately
and requires refusal with no output/staging directory. It also checks that
invalid limits and Int64 overflow cause no HTTP contact. These are enforcement
checks, not measurements of hard process RSS or total socket traffic.

## Admission before publication

```text
moonoci registry-admit https://registry.example.org team/app release \
  sha256:<trusted-root> sha256:<subject> approved-release \
  --require-artifact application/spdx+json \
  --require-artifact application/vnd.in-toto+json
```

`admit_registry_release` requires an explicit nonempty set of caller-owned
artifact requirements. It validates that configuration before contacting the
network, acquires the verified candidate, and evaluates the existing artifact
policy. The result contains a decision and an optional layout: rejected
candidates return no layout. The CLI prints the structured decision and exits 5
without creating output/staging on rejection. Successful candidates are written
using the same no-overwrite publication rules as ordinary pulls.

The CLI requires at least one `--require-artifact TYPE` (each means 1..128 verified
attachments); duplicate types are errors. It discovers all types, so
`--artifact-type` filtering is not accepted for admission. Library hosts may set
different bounded minimum/maximum counts through `ArtifactRequirement`. This
policy establishes typed attachment presence/content/association only; external
document validators and signer-trust policy remain separate host integrations.

## Explicit CONNECT proxies

`RegistryOptions.proxy_origin` / `--proxy-origin http://proxy.example:3128`
selects a caller-approved HTTP or HTTPS CONNECT proxy. Ambient proxy environment
variables are not imported. Origins must exclude userinfo, paths, queries and
fragments. Proxy authentication is not implemented. The option itself explicitly
permits the proxy transport scheme; registry HTTP still requires `--allow-http`.

The Registry, token endpoint and allowed blob origin retain their own end-to-end
TLS hostname/chain checks inside the tunnel. Custom roots apply to both an HTTPS
proxy and the target. Registry Authorization is not placed on CONNECT requests.
The HTTP request counter/budget counts logical Registry/token GET attempts;
each may additionally require one CONNECT. Proxy setup is included in request
timeouts; all handles close on refusal/cancellation. An HTTP target inside a
tunnel is plaintext and visible to the chosen proxy.

The local TLS fixture executes both HTTP and HTTPS proxy paths, checks that
Registry Authorization reaches the target but not CONNECT headers, retains
default certificate distrust, and refuses a 407 proxy response without output.
It binds only loopback and forwards only to the fixture's exact authority.

## Acquire an approved attachment set

\`registry-bundle\` and \`registry-admit\` accept a comma-separated list of
1–128 manifest digests with \`--attachment-pins\`. Use the attachment digests
from the approved publication plan. The client follows the full bounded
Referrers API listing, checks that every approved digest is advertised,
and fetches only those manifests and their payloads. If an approved digest
is missing, the check stops before downloading any image or attachment
content. Image content and each attachment's actual subject association
are still verified on a successful acquisition.

\`\`\`text
moonoci registry-bundle ORIGIN REPOSITORY TAG ROOT ROOT OUTPUT --attachment-pins SBOM_PIN,PROOF_PIN
moonoci registry-admit ORIGIN REPOSITORY TAG ROOT ROOT OUTPUT --attachment-pins PROOF_PIN --exact-referrers --require-artifact application/vnd.in-toto+json --statement-digest PROOF_PIN --statement-predicate PREDICATE
\`\`\`

Add \`--exact-referrers\` to refuse any additional advertised digest. This
checks the pages the Registry returned. The Registry can withhold data,
so a listing is insufficient evidence of what is stored elsewhere.
The option is incompatible with \`--artifact-type\`, which would limit
the listing before comparison. Required types and optional Statement
checks apply to the selected bundle, and a required Statement pin must
be in the selected set.

The ArtifactDock consumer exercised both modes with and without a later
attachment. Selection avoided 66,198 accepted network bytes in that fixture.

### Pass a reviewed lock between systems

\`registry-plan-bundle\` returns \`referrerLock\`, and
\`registry-promote-bundle-plan\` returns it under \`bundle.referrerLock\`.
The lock contains the exact release root, subject and approved attachment
digests. Save its \`document\` string as UTF-8 bytes without a BOM or appended
newline. Convey its \`pin\` through the same trusted channel as the release
approval. The receiver verifies this pin before parsing the file and compares
its root and subject with the requested release before connecting.

\`\`\`text
moonoci registry-bundle ORIGIN REPOSITORY TAG ROOT SUBJECT OUTPUT --referrer-lock LOCK_FILE --referrer-lock-pin LOCK_PIN
\`\`\`

The lock covers content identity across repositories. The receiver still
chooses and validates its Registry origin. To reject extra advertisements,
add \`--exact-referrers\`. The ArtifactDock consumer writes the exact lock
bytes from the promotion plan, rejects edits to those bytes, and reuses
the same document after restarting the server on a new port.
