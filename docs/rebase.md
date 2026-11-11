# Replace a pinned OCI image base

```text
moonoci rebase-plan APP OLD_BASE NEW_BASE APP_PIN OLD_PIN NEW_PIN
moonoci rebase APP OLD_BASE NEW_BASE APP_PIN OLD_PIN NEW_PIN REF OUTPUT [NEW_BASE_NAME]
```

Use three single-image OCI layouts and three trusted manifest digests. MoonOCI
verifies the three manifests, their config and layer contents, and their exact
platforms. The previous base's uncompressed DiffIDs must equal the prefix of
the application layer chain. This permits the same tar content to use different
compression in the previous base and the application. Any existing application
base digest annotation must agree with `OLD_PIN`. [OCI image configuration](https://github.com/opencontainers/image-spec/blob/v1.1.1/config.md)

The plan reports the layers to remove, insert and retain. When applying it,
the program writes a new layout to a fresh output path. It retains the
application's layer bytes and runtime configuration, updates DiffIDs and base
annotations, and verifies the resulting filesystem. The original application
and both bases remain usable by their original digests.

If all three configs contain history, each nonempty history entry must account
for one layer, and the old history must be an exact prefix of the application
history. The new history combines the replacement base's entries with the
application suffix. Inputs may also all omit history. Existing signatures and
attachments are associated with their original subject digests. Use the
emitted index digest for later offline review or a Registry publication plan.

Layer reuse is useful for replacing a compatible base after an upstream fix.
The resulting image still needs the application's runtime and deployment tests.
The tool verifies the image format and filesystem, including whiteouts and
content identities.

```text
moon build --target native --deny-warn
python scripts/rebase_chain.py --binary _build/native/debug/build/cmd/moonoci/moonoci.exe
```

The consumer confirms byte-for-byte reuse of the app layer, checks the updated
base and removed path independently, and rejects an unrelated old base.
