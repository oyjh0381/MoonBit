# Release workflows after 0.2.0

MoonOCI owns the steps from build output to verified OCI content. The MoonBit
ecosystem also provides an OCI server in ArtifactDock, a Wasm package client in
`oci_wasm`, and runtime capabilities in `wacon`. These make downstream
interoperability useful to test. Their existence also shapes which functionality
MoonOCI needs to own. [ArtifactDock](https://mooncakes.io/docs/Hhsqoo/artifactdock)
[oci_wasm](https://mooncakes.io/docs/mizchi/oci_wasm)
[wacon](https://mooncakes.io/docs/mizchi/wacon)

| Workflow | Deliverable | Acceptance evidence |
| --- | --- | --- |
| Select offline releases by name | Resolve an exact root name under a trusted index digest and export its reviewed image, index and attachment closure | Compare named and digest-based export byte for byte. Reject stale reviews and ambiguous names |
| Distribute MoonBit Wasm output | Pack and inspect CNCF v0 single-layer Wasm artifacts. Export the verified payload through a Native CLI | ORAS reads a real MoonBit build, and MoonOCI independently consumes an ORAS-produced layout. Record the original and recovered payload digests |
| Publish reviewed layouts to a Registry | Derive the upload order from the verified catalog. Bind repository, tag, source and object order to a review digest. Upload missing content and publish the tag after its dependencies | Test against a local OCI Registry, verify through an independent client, and retry after a controlled failed upload. Check that an incorrect review digest causes zero requests |
| Review a multi-platform rollout | Define the required platform matrix and compare verified source and candidate releases. Report missing or ambiguous matches and per-platform content changes | Compare with an independent OCI reader using distinct platform variants and shared layers. Exercise a missing required platform and a no-change release |

The offline and Wasm workflows are usable through the current CLI. Registry
publication currently has a portable plan, a local CLI command and upload-path
validation. HTTP execution and external verification are separate milestones.
The rollout matrix is a design target.

For registry publication, send blobs through the standard POST/PUT session,
send child manifests before their parent, and publish the selected root under
its explicit tag. A server upload location must stay inside the original
repository and origin. The review pin covers the source index and full physical
store, the exact destination, and ordered object descriptors. A tag is visible
after the final registry write. Previously uploaded content can remain after a
failure, so retries must reconcile by digest before continuing. Registry tag
concurrency requires a separate documented server contract. [OCI Distribution
1.1.1](https://github.com/opencontainers/distribution-spec/blob/v1.1.1/spec.md)

```text
moonoci registry-plan artifact EXPECTED_INDEX_PIN fixture https://registry.example team/modules release
```

This command performs bounded local reads and emits the ordered plan with its
review digest. It makes no connection to the registry.

The publication planner visits each reachable metadata digest once and each
strong edge once. It uses digest sets for deduplication, with separate
membership for the blob and manifest endpoints. This is linear in the
selected graph after catalog verification. The Native host loads bytes into
memory subject to the catalog and filesystem budgets.
