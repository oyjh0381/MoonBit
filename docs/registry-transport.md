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

## Referrer discovery profile

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
