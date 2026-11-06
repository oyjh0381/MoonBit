# Mixed-content retention and reviewed copies

The unreleased 0.2.0 `lifecycle` package retains OCI images, nested indexes and
typed attachments together. It addresses offline cache/export tooling where
image-only reachability would omit supply-chain attachments. It provides a
reviewable copy plan, not an in-place filesystem garbage collector.

## Executable Windows/Linux consumer

```text
moon build --target native --release --deny-warn
python scripts/retention_chain.py --binary _build/native/release/build/cmd/moonoci/moonoci.exe
```

Add `--oras PATH_TO_ORAS` to independently check attachment discovery. Windows
has actually executed this chain with ORAS 1.3.6. The fixture creates two platform
images, an attachment on their original release index, separate per-image
attachments and an attachment on another attachment. These JSON payloads are
illustrative typed documents, not verified SBOMs, signatures or signer identity.

The independently checked app export retained 8 of 16 physical Blobs: 4,028 of
6,564 bytes, omitting 2,536 bytes from the new copy. It preserved its two-level
attachment chain, both root aliases and extension fields, while excluding the
other platform, its attachment, the release-level graph and an orphan Blob.
Those are synthetic fixture counts, not production compression or speed claims.
The source was unchanged by export; later deliberate corruptions in the script
test rejection and do not represent mutations performed by the library.

CPython derives literal expected content sets and independently computes the
physical store and review pins. It checks rewritten root bytes, uses the existing
independent image observer and invokes ORAS for app/index-subject discovery.
Wrong/stale pins, overwritten destinations, corrupt orphan bytes and an image
with hash-valid but invalid tar content are refused before output publication.

## Public flow

1. `catalog(layout, expected_index)` verifies every physical SHA-256 Blob's
   actual size/digest and refuses duplicate physical records. It snapshots the
   marker, root and physical membership under quotas, then parses recognized
   metadata with memoized digest lookup and repeated-descriptor size checks.
2. `catalog.retain(roots, policy=...)` computes selected roots' strong closures
   and applies explicit weak-link policy. Roots must name recognized local
   metadata; empty/duplicate/unknown selections are errors.
3. `retention_json(plan)` reports selected roots, kept/discarded content, policy,
   source index/store pins, output pin, review pin and candidate byte savings.
   `plan.materialize()` returns a separate in-memory layout; the catalog is an
   immutable snapshot. These content APIs do not inspect image layer semantics.
4. `plan.apply(current, expected_plan)` binds caller review to that exact plan
   and revalidates current root and physical membership. Even adding an orphan
   with an unchanged index invalidates the old decision. It returns a copy.
5. Native `export_retained_layout` reconstructs the plan from a bounded fresh
   filesystem load, compares the review pin and runs the supported mixed-store
   semantic verifier before staging a new destination. It never deletes source
   files or replaces an existing destination.

The CLI exposes the same process:

```text
moonoci content-catalog INPUT EXPECTED_INDEX_PIN
moonoci retain-plan INPUT EXPECTED_INDEX_PIN MODE ROOT [ROOT...]
moonoci retain-export INPUT EXPECTED_INDEX_PIN PLAN_PIN MODE OUTPUT ROOT [ROOT...]
```

| Mode | Incoming attachments | Outgoing weak subject |
| --- | --- | --- |
| `closure` | Excluded unless directly selected/strongly reachable | External descriptor retained |
| `referrers` | Retained recursively; library default | External descriptor retained |
| `complete` | Retained recursively | Requires and retains local subject closure |

For an image cache, `referrers` keeps the image's SBOM-like attachments and their
own attachments. Selecting an index keeps its platform branches and attachments
on that exact index. Selecting only an artifact in `closure` can intentionally
leave its subject external. `complete` follows local subjects and may therefore
also retain their other attachments; it refuses unavailable external subjects.

The plan records all discarded digests and savings for caller review. They are
not automatic deletion instructions or evidence that arbitrary consumers no
longer need those objects. Host retention roots and any later deletion policy
remain caller decisions.

## Identity and interoperability

The store fingerprint hashes the root pin, marker pin and digest-sorted physical
SHA-256 digest/size pairs under a versioned MoonOCI domain prefix. Review identity
also binds exact output index bytes, both policy flags, sorted explicit roots and
kept/discarded sets. These unsigned digests do not authenticate a signer or prove
that a caller approved an action; the trusted expected pin comes from the host.

Retained manifests, nested indexes, payloads and config bytes are copied exactly.
Subjects keep their original digest; the export never rebinds an old attachment
to a rewritten root. All original root aliases for retained advertised digests
are kept. Automatically retained metadata is advertised for independent clients.
When root advertisements do not change, the original root bytes/pin are reused.
Otherwise the root's unknown fields and retained raw descriptor extension fields
are preserved, keys are sorted and exact scalar number spellings are retained.
This stable rewrite is not RFC 8785 canonicalization or a signature format.

## Limits and verification boundaries

Catalog defaults: 65,536 physical Blobs, 262,144 descriptor edges, depth 64,
1 GiB physical data and 128 MiB metadata. Configurable hard ceilings are 65,536,
1,000,000 edges, depth 128, 8 GiB data and 512 MiB metadata. Individual parsed JSON
documents and rewritten root output remain capped at 16 MiB. Memoized subtree
height checks still enforce depth when the same subtree appears on a deeper path.

Native bounded loading defaults to 4,096 Blobs, 256 MiB per Blob, 512 MiB total
input including root/marker, 16 MiB index and a 4 KiB marker. It incrementally
enumerates directories and preflights Blob sizes before allocating their content.
The resulting layout still retains all loaded bytes. These logical limits do not
measure peak RSS or provide a general memory sandbox. The legacy `load_layout`
API remains available and has not acquired these quotas automatically.

The catalog proves physical content integrity and known metadata topology only.
It does not validate DiffIDs, tar/gzip interpretation, platform compatibility,
artifact schemas or signatures. The Native export adds `verify_store` checks
within that verifier's documented scope. A hash-valid invalid tar can produce a
content plan but is refused by Native export, as tested by the consumer.

Known structural fields are `index.manifests` and `manifest.config/layers`.
Manifest payloads remain opaque even when their declared media type resembles
metadata. `subject` is separately handled as a weak link. Locally present subject
metadata is checked; missing weak subjects are allowed until `complete` requires
them. Unknown advertised metadata formats are refused by this conservative
planning profile, not declared invalid OCI. Unknown extension-defined references,
remote URLs/inline-data fallback and unsupported algorithms are not traversed.

Filesystem copying covers `oci-layout`, `index.json` and SHA-256 Blob content.
Auxiliary files such as Docker compatibility manifests, logs or README files are
not copied or included in the physical store pin. The bounded loader rejects
other Blob algorithm directories rather than quietly omitting them. Corrupt or
ambiguous orphan content also blocks a plan; callers may inspect/quarantine it
separately. This tool does not silently delete broken evidence.

Hosts own trusted parent directories, keep inputs quiescent and serialize access.
Direct marker/index/Blob paths reject symlinks, but parent-directory races,
descriptor-relative sandboxing, concurrent writers, directory crash durability,
Registry GC and background retention scheduling are outside this adapter.

## Workload measurements

```text
python scripts/retention_benchmark.py --binary _build/native/release/build/cmd/moonoci/moonoci.exe --runs 3
```

This builds independently authored 100/1,000-image stores with one attachment per
image and a shared real layer. It measures small selections and a complete index
selection, validates literal expected closures and all emitted content hashes,
and reports planning versus verified export wall times separately under `_build`.
Measurements include startup, bounded filesystem loading and hashing. They do not
compare against Registry garbage collectors or measure peak process memory.

For N stored bytes, V objects and E known edges, catalog content hashing and
topology parsing cost O(N + V + E), plus digest sorting O(V log V). Memoization
prevents expansion of repeated DAG branches; each physical Blob is hashed once
for catalog preparation. Retention uses an indexed queue and reverse subject
edges, O(V + E) worst case plus sorted announcements. Snapshot/plan wrappers reuse
immutable Bytes rather than duplicate payload buffers. Applying an old plan costs
a new full source validation. Native export's semantic checks and staged file IO
add their own costs; no claim is made that the complete workflow is sublinear.
