# MoonOCI Build Specification v1

The Build Specification is strict configuration owned by the caller. Unlike OCI documents, unknown fields are rejected so misspelled security or runtime settings cannot be silently ignored. Input must be UTF-8 JSON no larger than 16 MiB, nesting is limited to 128 levels, and duplicate object keys—including equivalent escaped keys—are rejected.

## Root object

| Field | Type | Required | Default |
| --- | --- | --- | --- |
| `schemaVersion` | integer | yes | must be `1` |
| `ref` | string | no | `latest` |
| `platform` | object | no | Linux/amd64 |
| `layers` | non-empty array | yes | none |
| `config` | object | no | empty runtime configuration |
| `created` | RFC 3339 string | no | omitted |
| `author` | string | no | omitted |
| `annotations` | string map | no | empty |
| `output` | object | no | `{ "layout": "oci-layout" }` |

MoonOCI never reads the current clock. An explicit `created` value takes precedence; otherwise the Native builder converts `SOURCE_DATE_EPOCH` seconds to canonical UTC RFC 3339. If neither is present, creation metadata is omitted.

## Platform

Allowed fields are `os`, `architecture`, `variant`, and `osVersion`. `os` and `architecture` default to `linux` and `amd64` and may not be empty.

## Layers

Every layer object requires `source`, the Native directory containing additions and replacements for that changeset.

| Field | Type | Meaning |
| --- | --- | --- |
| `source` | string | Layer Source directory |
| `compression` | `none` or `gzip` | stored Blob encoding; default `none` |
| `hardlinks` | string map | explicit archive-relative hardlink path to same-layer regular file |
| `remove` | string array | root-relative paths encoded as Whiteouts |
| `opaque` | string array | directories encoded with opaque markers |
| `exclude` | string array | `*`/`?` patterns applied to portable `/` paths |
| `ignoreFile` | string | optional pattern file in the Layer Source root |
| `metadata` | object | normalization overrides |

`remove` and `opaque` paths accept one leading `/` for convenience. Absolute host paths, drive-letter paths, UNC paths, backslashes, empty segments, `.` and `..` segments are rejected.

Whiteouts affect lower layers. Use the same path in the layer source and
\`remove\` to explicitly discard its lower contents before adding a replacement.
Use \`"opaque": ["/"]\` to hide the entire lower filesystem while retaining
the files added by the current layer. The \`verify\` command checks that
filesystem transitions can be applied as well as verifying layer digests.
The builder preserves numeric owner IDs up to 2,147,483,647, using a PAX
header when a value exceeds the USTAR octal field. The layer reader also
accepts positive GNU base-256 numeric fields and conventional \`./\` paths.

Declare explicit hardlinks with `{"hardlinks":{"bin/alias":"bin/tool"}}`.
Targets must belong to the current layer and resolve to regular files. The
writer emits each target before its links, so JSON key order has no effect
on the output. The inventory reports the original file content and metadata
for each alias, including after an upper layer replaces the original path.
Cross-layer hardlink creation is outside this profile.

Metadata fields are `mode`, `uid`, `gid`, `mtime`, and `preserveMtime`. Defaults normalize ownership to `0:0`, mtime to `0`, regular files to mode `0644`, directories to `0755`, and symlinks to `0777`. Explicit `mode`, `uid`, `gid`, and `mtime` override those values. Native mode and ownership preservation are outside the v1 schema; mtime preservation is supported.

## Runtime configuration

The `config` object accepts `user`, `env`, `entrypoint`, `cmd`, `workingDir`, `labels`, `exposedPorts`, `volumes`, and `stopSignal`. `env` and `labels` are string maps. `workingDir` defaults to `/` and must be an absolute container path.

## Output

`output.layout` names the new OCI Image Layout directory. MoonOCI writes into a sibling staging directory and renames it after all content is present. Existing output or staging paths are never overwritten.

## Complete example

```json
{
  "schemaVersion": 1,
  "ref": "example-v1",
  "platform": { "os": "linux", "architecture": "amd64" },
  "layers": [
    {
      "source": "rootfs/base",
      "compression": "none",
      "exclude": ["tmp/*"]
    },
    {
      "source": "rootfs/update",
      "compression": "gzip",
      "remove": ["/etc/obsolete.conf"],
      "opaque": ["/var/cache"]
    }
  ],
  "config": {
    "env": { "APP_ENV": "production" },
    "entrypoint": ["/app/server"],
    "workingDir": "/app"
  },
  "created": "2026-01-01T00:00:00Z",
  "output": { "layout": "dist/example" }
}
```

### Import existing layer archives

A layer can use `sourceTar` instead of a source directory. For an
uncompressed tar, set `path` and the independently obtained `diffId`.
The optional layer `compression` determines storage while the tar bytes
and DiffID stay identical.

```json
{"sourceTar":{"path":"base-layer.tar","diffId":"sha256:DIGEST"},"compression":"gzip"}
```

Use `encoding: "gzip"` with both `blobDigest` and `diffId` to reuse an
existing compressed layer. MoonOCI checks both pins and stores the exact
compressed bytes. Omit `compression` for this form. Source archives can
contain whiteouts and same-layer hardlinks. Put directory edits in separate
layers. Each imported file and its expanded tar are limited to 256 MiB.

Run `moonoci layer-chain IMAGE_LAYOUT linux amd64` to inspect each stored
blob digest, uncompressed DiffID, and OCI ChainID. ChainID identifies the
ordered prefix of filesystem changes. Storing the same tar with different
compression changes the blob digest while preserving the ChainIDs.

### Transcode a verified image

```text
moonoci transcode-image INPUT MANIFEST_PIN gzip OUTPUT
moonoci transcode-image INPUT MANIFEST_PIN none OUTPUT
```

The command selects a unique digest in the top-level OCI index and produces
a standalone image in a new directory. It preserves config bytes, DiffIDs
and ChainIDs. It writes new storage descriptors only where the encoding
changes and preserves unrelated metadata fields in those descriptors. A
changed descriptor with inline data or external URLs is rejected because
those fields identify the prior bytes. Subject-bound artifacts require
their own derivation.

The independent filesystem consumer compares the actual decompressed tar
bytes for each layer, then converts back and checks the original manifest
digest. A no-op conversion retains the original manifest bytes.

Append --layers with comma-separated zero-based positions to choose which
layers to transcode. All unselected layer descriptors and blobs are retained.

Use `--dry-run` to compute and verify the output without creating the target.
Pass the reported `resultIndex` back as `--expect-index DIGEST` to reject
any change in the derived index before writing the layout.

For reviewed inputs, pass `--expect-source-index DIGEST` to pin the original
index metadata as well as the selected manifest. The receipt records both
the source and derived index digests.

Set `--max-layer-bytes BYTES` to cap the sum of the output's unique stored
layer blobs. The receipt shows the original and output layer byte totals.
These totals exclude the config, manifest, index and layout marker.

### Review an image storage migration

For an opt-in DEFLATE conversion, add `--gzip-level 6`. The default level
`0` keeps the existing deterministic stored-block gzip behavior.
Levels `1`–`9` apply only when an uncompressed layer is converted to gzip.
Existing gzip blobs keep their bytes. Newly encoded data must stay within
MoonOCI's 200:1 expansion limit.

`--only-if-smaller` retains each original layer when the proposed blob
does not shrink. `--min-layer-savings N` separately requires a net reduction
of at least `N` bytes across all unique stored layers. That aggregate check
also accounts for duplicate blobs and partially selected conversions.

Preview the candidate, then repeat with the exact source and output index
pins from its receipt:

```text
moonoci transcode-image BEFORE BEFORE_PIN gzip AFTER --gzip-level 6 --only-if-smaller --min-layer-savings 1 --dry-run
moonoci transcode-image BEFORE BEFORE_PIN gzip AFTER --gzip-level 6 --only-if-smaller --min-layer-savings 1 --expect-source-index BEFORE_INDEX --expect-index AFTER_INDEX
moonoci compare-image-storage BEFORE BEFORE_PIN AFTER AFTER_PIN --expect-before-index BEFORE_INDEX --expect-after-index AFTER_INDEX --require-runtime-identity --max-new-blob-bytes 4194304
```

`AFTER_PIN` is the candidate manifest from the transcode receipt. The
comparison also works on images produced by other OCI tools. It verifies
both layouts before comparing the exact config bytes and ordered DiffIDs.
The first differing layer is reported at its zero-based position. A missing
side means that image's layer sequence ended there.

The transfer budget counts unique candidate manifest, config and layer blobs
absent from the selected baseline image. The counts exclude index, layout
marker, protocol overhead and content cached from other images. A failed gate
returns exit code 5 with a JSON decision. The identity gate covers the image
config and uncompressed layers. Manifest annotations, tag state and signatures
require separate checks.

`scripts/rootfs_transition_chain.py` checks gates and exit codes against
CPython on synthetic layers. `scripts/public_image_chain.py` uses the pinned
Alpine linux/amd64 image to check the index, exact decompressed tar bytes and
migration byte counts. Run it with a local ORAS binary or an existing OCI
layout for that manifest:

```text
python scripts/public_image_chain.py --binary _build/native/release/build/cmd/moonoci/moonoci.exe --oras PATH_TO_ORAS
```
