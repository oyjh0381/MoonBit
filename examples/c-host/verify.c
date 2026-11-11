#ifdef _MSC_VER
#define _CRT_SECURE_NO_WARNINGS
#endif

#include "moonbit.h"
#include "moonoci.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_INPUT_BYTES (16L * 1024L * 1024L)

int main(int argc, char **argv) {
  if (argc != 4) {
    fputs("usage: moonoci-c-verify blob|index|manifest FILE SHA256\n", stderr);
    return MOONOCI_BAD_ARGUMENT;
  }
  int32_t kind;
  if (strcmp(argv[1], "blob") == 0) {
    kind = MOONOCI_BLOB;
  } else if (strcmp(argv[1], "index") == 0) {
    kind = MOONOCI_INDEX;
  } else if (strcmp(argv[1], "manifest") == 0) {
    kind = MOONOCI_MANIFEST;
  } else {
    return MOONOCI_BAD_ARGUMENT;
  }
  FILE *input = fopen(argv[2], "rb");
  if (input == NULL) {
    return 6;
  }
  long size = -1;
  if (fseek(input, 0, SEEK_END) == 0) {
    size = ftell(input);
  }
  if (size < 0 || size > MAX_INPUT_BYTES || fseek(input, 0, SEEK_SET) != 0) {
    fclose(input);
    return size > MAX_INPUT_BYTES ? MOONOCI_INPUT_LIMIT : 6;
  }
  size_t bytes = (size_t)size;
  unsigned char *data = bytes == 0 ? NULL : malloc(bytes);
  if (bytes != 0 && (data == NULL || fread(data, 1, bytes, input) != bytes)) {
    free(data);
    fclose(input);
    return 6;
  }
  if (fgetc(input) != EOF || ferror(input)) {
    free(data);
    fclose(input);
    return 6;
  }
  fclose(input);

  moonbit_init();
  if (moonoci_c_abi_version() != 1) {
    free(data);
    return 6;
  }
  int32_t status = moonoci_verify_entity(data, bytes, argv[3], strlen(argv[3]), kind);
  free(data);
  printf("moonoci C ABI 1 status=%d\n", (int)status);
  return status;
}
