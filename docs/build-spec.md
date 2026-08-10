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

MoonOCI never reads the current clock. A caller that requires creation metadata must supply `created` explicitly. `SOURCE_DATE_EPOCH` conversion is left to the invoking build system in v0.1.

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

Metadata fields are `mode`, `uid`, `gid`, `mtime`, `preserveMode`, `preserveOwnership`, and `preserveMtime`. Defaults normalize ownership to `0:0`, mtime to `0`, regular files to mode `0644`, directories to `0755`, and symlinks to `0777`. Explicit `mode`, `uid`, `gid`, and `mtime` override those values. Native mode and ownership preservation are not available in v0.1 and fail explicitly; mtime preservation is supported.

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
