#include "moonbit.h"
#include <string.h>

int32_t moonoci_host_buffer_is_null(void *buffer) {
  return buffer == NULL;
}

moonbit_bytes_t moonoci_host_copy_buffer(void *buffer, int32_t length) {
  moonbit_bytes_t result = moonbit_make_bytes_raw(length);
  if (length > 0) {
    memcpy(result, buffer, (size_t)length);
  }
  return result;
}
