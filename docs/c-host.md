# Verifying pinned OCI objects from C

MoonBit 0.10.20 can build a Native static library for a host program.
MoonOCI exposes a small C ABI for clients that already hold downloaded or
cached OCI bytes and a trusted SHA-256 pin. [MoonBit Native FFI](https://docs.moonbitlang.com/en/latest/language/ffi.html#native-static-libraries)

```text
moon build adapter/chost --target native --release --deny-warn
python scripts/c_host_chain.py --archive PATH_PRINTED_BY_MOON
```

On Windows, run the C consumer in the MSVC Developer Command Prompt.
On Linux, it uses `cc`. Link the archive with the host and include
`adapter/chost/moonoci.h` and MoonBit's `moonbit.h`. Call
`moonbit_init()` once before use, then check that
`moonoci_c_abi_version()` returns 1. The host is responsible for coordinating
runtime initialization and serializing calls.

`moonoci_verify_entity` takes caller-owned buffers and explicit lengths.
The digest is a 71-byte lowercase `sha256:` string. It copies the entity
once after rejecting sizes above 16 MiB, compares the digest, then parses an
OCI index or image manifest if requested. For blobs it verifies the raw
bytes alone. An empty blob may use a null data pointer. Supply readable
buffers for all nonzero lengths. The function reads no file, follows no
references and makes no network request.

The header defines status codes for malformed arguments, digest mismatch,
invalid OCI documents and size limits. Verification covers the one supplied
object. Use the MoonOCI graph APIs to verify referenced blobs and filesystems.
The C sample in `examples/c-host/verify.c` reads a file and demonstrates the
ABI. The test uses Python to compute independent pins and validates both
success and failure return codes against the linked archive.
