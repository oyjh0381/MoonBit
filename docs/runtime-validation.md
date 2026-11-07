# Validation without a local Linux VM

Windows can validate the portable library and observe OCI output independently.
Actual Linux process execution is delegated to a Linux CI runner. The two kinds
of evidence have distinct meanings and must not be reported interchangeably.

## Local independent observation

```text
moon test --target all --deny-warn
moon run cmd/moonoci --target native -- build examples/native-build/moonoci.json
python scripts/independent_layout.py _build/ci-layout
```

The Python reader uses stdlib JSON, SHA-256, gzip and tar implementations. It
checks descriptor sizes/digests, DiffIDs, platform metadata and observes tar
entries without extracting them. It is intended for bounded, trusted test
fixtures: gzip memory and archive count are not sandboxed, and its filesystem
observation is not a complete reference implementation of all OCI semantics.

## Linux consumption chain

```sh
python3 scripts/runtime_chain.py
```

Prerequisites: Linux, MoonBit 0.10.16, a C compiler, Python 3, ldd, Skopeo and
Podman. The CI `runtime-consumer` job provides this environment remotely.

The hosted CI invocation uses `--rootful` to run Podman through sudo. Runtime
storage uses a short OS temporary directory, the vfs driver, file events and
disabled container cgroups. The verifier runs with a 60-second container limit.
This avoids dependencies on a runner's user container store and systemd session.

1. Compile the real Native MoonOCI CLI.
2. Build a fixture layout with MoonOCI.
3. Package the CLI, its resolved loader/shared libraries and fixture into a new
   OCI image. No base image or registry download is required by this chain.
4. Independently inspect the image with Python and Skopeo; verify rebuilding
   gives the same index and Skopeo sees the same manifest digest.
5. Export an OCI archive, copy the layout to local container storage and run
   MoonOCI inside Podman to verify the embedded fixture.
6. Require the expected successful verifier output. The container runs without
   network, with a read-only rootfs, dropped capabilities and a non-root user.

The chain retains a machine-readable report under `_build/runtime-*/`; CI
uploads it as an artifact. Dependencies and source inputs must stay quiescent
while building. This is reproducibility under the same declared binary/library
inputs, not a claim of cross-toolchain reproducible executable compilation.

This consumer is a self-hosted integration using the real product, not an
external adoption claim. At initial implementation the Windows test and local
Python observation passed; the Linux runtime script has not yet been executed.
After an authorized push, inspect the actual CI result before claiming runtime
interoperability. No local VM is required.

## Distribution APIs

`distribution.merge` composes flat, verified image manifests into a deterministic
multi-platform index, rejects duplicate identities and mismatched platform
metadata, and deduplicates content. `select` uses exact OS/architecture/variant/
OS-version matching. `slice` produces an independently verifiable selected
layout. `missing_blobs` plans missing target content against a verified base;
it does not by itself create an importable delta archive. `verify_pin` checks an
externally supplied index digest, whose authenticity the caller must establish.

CLI: `merge OUTPUT INPUT INPUT...`, `select INPUT OUTPUT OS ARCH`, `delta BASE
TARGET`. Variant/version selection is available through the library API.
See the [nested index profile](nested-indexes.md), [Registry transport and
public-image consumer](registry-transport.md), and [Statement binding
profile](statement-verification.md) for the current source capabilities.
