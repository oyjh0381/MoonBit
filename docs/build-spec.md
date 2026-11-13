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
