# Security model

MoonOCI processes untrusted Build Specifications, tar Layers, OCI JSON, and content-addressed Blobs. Correctness checks run before convenience behavior.

## Path policy

Archive paths must be relative UTF-8 paths using `/`. Empty paths, absolute paths, drive letters, UNC forms, NUL, backslashes, empty segments, and `.`/`..` segments are rejected. Paths and symbolic-link targets are limited to 4096 UTF-8 bytes. Native traversal does not follow symbolic links and v0.1 rejects them because a portable read-link API is unavailable.

## Archive policy

The reader checks 512-byte framing, header checksum, octal overflow, payload bounds, padding, two zero terminators, duplicate paths, UTF-8, and entry count. It supports regular files, directories, symlinks, POSIX PAX path/linkpath records, and GNU longname/longlink records. Sparse files, devices, sockets, FIFOs, and unknown type flags are rejected.

The default maximum is 1,000,000 entries. gzip build input is limited to 256 MiB. Verification limits decompressed output to 512 MiB and rejects expansion above 200:1. CRC32 and ISIZE are validated by the gzip decoder.

## JSON and descriptor policy

JSON is limited to 16 MiB and 128 nesting levels. Duplicate object keys are rejected before parsing. Build Specifications reject unknown fields; OCI documents tolerate unknown extension fields but require the fields MoonOCI consumes. SHA-256 Digests must contain exactly 64 lowercase hexadecimal characters.

Verification follows the Image Index → Image Manifest → Image Configuration/Layer graph and checks every referenced Blob's existence, byte size, and Digest. Layer tar bytes are parsed and their uncompressed Digest is compared with the corresponding DiffID.

## Output policy

Native builds refuse existing destinations. Files are written to a scoped staging directory and renamed only after the complete layout is present. On failure, MoonOCI attempts to remove only that exact staging directory. Archive export refuses to overwrite an existing file.

## Resource considerations

The in-memory v0.1 API materializes Layer and JSON bytes. It is appropriate for the documented limits but not for multi-gigabyte images. Future streaming adapters must preserve the same Digest, size, and decompression limits.
