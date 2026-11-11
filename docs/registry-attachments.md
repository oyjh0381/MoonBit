# Publish a release with approved attachments

```text
moonoci registry-plan-bundle INPUT INDEX_PIN REF ORIGIN REPO TAG ATTACHMENT_PINS
moonoci registry-publish-bundle INPUT INDEX_PIN REF ORIGIN REPO TAG ATTACHMENT_PINS BUNDLE_PIN
```

`ATTACHMENT_PINS` is a comma-separated list of one to 128 SHA-256 manifest
digests. Each must be an immediate referrer of the named release root. The
planner verifies the payloads and subject descriptor, deduplicates shared
blobs, and binds the selected digests and destination to `BUNDLE_PIN`.
Attachment type labels describe the OCI packaging. Verify the SBOM,
attestation or signature content with the appropriate consumer.

The executor stages the release root by digest, uploads the approved
attachments, and reads their exact manifest bytes back. A new attachment PUT
must acknowledge the subject. Before writing the tag, the executor follows the
bounded Referrers API listing and matches each approved digest, size, media
type and artifact type. The tag is read back and verified. [OCI Distribution
1.1.1](https://github.com/opencontainers/distribution-spec/blob/v1.1.1/spec.md)

This workflow requires an OCI 1.1 Registry with Referrers API support.
A missing acknowledgement or listing stops the operation before the final
tag write. Staged content may remain by digest. A repeat checks existing
objects and can reuse them. The command supports the same HTTPS, custom CA,
token and explicit plain-HTTP settings as ordinary Registry publication.

```text
python scripts/registry_attachment_chain.py --binary PATH_TO_MOONOCI --oras PATH_TO_ORAS --zot PATH_TO_ZOT
```

The Windows run published a two-platform index and two pinned attachments to
Zot. ORAS discovered the same two digest/type pairs. The retry transferred
zero bytes. A separate wire fixture omitted the acknowledgement and confirmed
that the final tag was never written.
