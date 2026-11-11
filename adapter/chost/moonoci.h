#ifndef MOONOCI_CHOST_H
#define MOONOCI_CHOST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum moonoci_entity_kind {
  MOONOCI_BLOB = 0,
  MOONOCI_INDEX = 1,
  MOONOCI_MANIFEST = 2
};

enum moonoci_verify_status {
  MOONOCI_VERIFIED = 0,
  MOONOCI_BAD_ARGUMENT = 2,
  MOONOCI_DIGEST_MISMATCH = 3,
  MOONOCI_INVALID_DOCUMENT = 4,
  MOONOCI_INPUT_LIMIT = 5
};

/* Call moonbit_init() once before using the library. */
int32_t moonoci_c_abi_version(void);

/*
 * Verifies up to 16 MiB. sha256 must point to 71 readable bytes with no
 * required terminator. data may be NULL when size is zero. Buffers are
 * read-only for this call and remain owned by the host.
 */
int32_t moonoci_verify_entity(void *data, uint64_t size,
                             void *sha256, uint64_t sha256_size,
                             int32_t kind);

#ifdef __cplusplus
}
#endif

#endif
