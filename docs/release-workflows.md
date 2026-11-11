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
| Embed OCI object verification in a C host | Link the MoonOCI Native static archive to verify pinned objects already in caller-owned memory | Build and run a C executable against the archive. Compare to independently computed SHA-256 digests and reject malformed or changed objects |
| Replace an image base while preserving application layers | Verify the old DiffID prefix, splice in the replacement layers, and produce a new verified OCI layout | Read the derived image independently. Verify exact app-layer reuse, updated base contents and preserved whiteouts |

The offline, Wasm and Registry publication workflows are usable through the
current CLI. The portable `rollout` package also provides coverage, two-release
comparison and a rollout policy decision. See [Multi-platform rollout review](rollout-review.md).
Native applications can link the [C verification library](c-host.md).
Release tools can preview and apply an [OCI base replacement](rebase.md).
The [Registry promotion gate](registry-promotion.md) binds complete rollout
approval to the exact destination and named release root.

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
moonoci registry-publish artifact EXPECTED_INDEX_PIN fixture https://registry.example team/modules release PLAN_PIN
```

The plan command performs bounded local reads and emits the ordered plan with
its review digest. The publish command reconstructs it and compares the
caller-supplied digest before any connection. It checks existing objects with
HEAD, sends missing content and reads the tag manifest back by digest and
size. The receipt counts child manifests separately from the final tag write.

The CLI accepts a pre-authorized bearer token in `MOONOCI_REGISTRY_PUSH_TOKEN`
for HTTPS. `--ca-file` supplies a private trust root. Plain HTTP is opt-in and
requires an empty token setting. The write client uses one origin, with no
automatic redirects or credential exchange. Publication accepts a missing tag
or an existing tag with identical content. Use one writer per destination tag,
because OCI Distribution does not define a compare-and-swap tag update.

On Windows, a two-platform layout with a shared layer was published to Zot
2.1.23. ORAS 1.3.6 copied all six objects back byte for byte. A repeat used
eight requests and uploaded zero bytes. The loopback fixture also injects a
failed upload, rejects an unrelated tag and rejects corrupted tag readback.

```text
python scripts/setup_zot.py
python scripts/registry_publish_chain.py --binary PATH_TO_MOONOCI --oras PATH_TO_ORAS --zot PATH_TO_ZOT
```

The Windows and Linux CI jobs verify the pinned Zot release's size and SHA-256
before starting it on a loopback port. [Zot v2.1.23 release](https://github.com/project-zot/zot/releases/tag/v2.1.23)

The publication planner visits each reachable metadata digest once and each
strong edge once. It uses digest sets for deduplication, with separate
membership for the blob and manifest endpoints. This is linear in the
selected graph after catalog verification. The Native host loads bytes into
memory subject to the catalog and filesystem budgets.
