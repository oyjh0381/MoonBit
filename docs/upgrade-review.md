# Content provenance and version-bound upgrade review

These are local 0.2.0 development APIs. They provide inspectable observations
and explicit host decisions, not a compatibility proof for every consumer.

## Final filesystem observations

`builder.inventory_from_manifest(layout, descriptor)` validates the graph and
root descriptor membership, applies the same whiteout/opaque transitions used
by construction, and reports each final path with type, mode, uid/gid/mtime,
content digest for regular files, link target, contributing layer index and
layer digest. Symlinks are never followed. Removed or hidden lower-layer files
do not appear in the final inventory. Bytes are not extracted to a filesystem.

`rootfs_from_manifest` offers the corresponding metadata-only query. As of
0.2.0, `rootfs_from_layout` requires exactly one image; callers of multi-image
layouts must select explicitly. This intentionally removes the old behavior of
silently reading the first index member. Use `distribution.select` for exact
platform selection, then pass that descriptor to either query.

```text
moonoci files LAYOUT linux amd64
moonoci diff BASE TARGET linux amd64
moonoci config-diff BASE TARGET linux amd64
```

`review.compare_files` compares final inventories by path. It distinguishes
additions, removals, same-size content changes, permission/owner/time changes,
link redirection and type changes. Recompression alone changes layer provenance
without changing the final filesystem; it is ignored by default and available
through the library's `include_provenance=true` option. Paths are sorted by UTF-8.
This is read-only comparison, not automatic generation of layer changesets.

`compare_configuration` observes platform, user, command, working directory,
environment sequence, signal, ports and volumes as changes requiring review.
Labels, creation information, author and history are reported as metadata.
Environment sequence changes are conservative observations, even if unique-key
reordering might not affect a particular runtime. JSON contains field names and
classifications, not environment values. These classifications do not prove a
change will break an application, and label consumers may impose their own rules.

## Approval is specific to two versions

`evaluate_upgrade` computes both comparisons itself from source layouts. An
`UpgradeApproval` must contain exact expected base and target manifest digests,
approved changed paths, approved changed runtime fields and whether additions
are permitted without individual review. Duplicate, stale, unknown or nonruntime
field approvals are rejected. Changing the candidate invalidates the old pins.
The host must authenticate these pins and the actor granting approval.

The CLI `upgrade-check BASE TARGET OS ARCH BASE_PIN TARGET_PIN` supplies no
approvals: it checks whether an upgrade can pass without reviewing changed files
or runtime fields. Exit 5 indicates a blocked decision or invalid pin; exit 0
indicates no outstanding review. Applications use the public library to supply
actual approvals. Metadata-only changes do not require runtime field approval
in this policy; independent release policies can still constrain labels.

Passing this gate records that a host accepted declared changes between pinned
images. It does not execute either image, inspect ABI compatibility or establish
that arbitrary clients are safe. The Linux runtime consumer remains separate.

## Reproducible cross-platform consumer

```text
moon build --target native --release --deny-warn
python scripts/independent_cases.py
python scripts/upgrade_chain.py --binary _build/native/release/build/cmd/moonoci/moonoci.exe
```

The consumer builds a baseline and layered candidate, overwrites a file with the
same byte count, removes another and adds configuration. It independently checks
content hashes, file attributes and layer provenance against CPython tar/gzip/
hashlib observations, verifies the exact change counts and configuration fields,
and requires review for an unapproved upgrade. A wrong candidate pin is refused.
Inputs and machine-readable evidence remain in ignored `_build/upgrade-*/`.

The development-only independent observer also has four literal checks for root
opacity, directory opacity, directory replacement and subtree deletion. They
follow [OCI layer changeset semantics](https://github.com/opencontainers/image-spec/blob/v1.1.1/layer.md).
These fixtures cover the project's supported file kinds and do not establish
full compatibility with all tar/device/hardlink/xattr or platform extensions.

## Costs

The new comparison maps cost expected O(F) plus O(F log F) path sorting after
inventory construction for F final paths. Content hashing is proportional to
regular-file bytes observed in layers. Existing graph verification and overlay
application still dominate large inputs: repeated platform/layer decoding and
the array-based transition engine can rescan content and paths. This is not a
streaming multi-GiB diff engine. Source buffers and transient decoded layers stay
in memory; provenance maps retain final survivors, not all historical versions.
