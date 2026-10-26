#include "podoco.h"

#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: ffi-smoke EXPECTED_VERSION\n");
    return 2;
  }
  if (podoco_abi_version() != 2) {
    fprintf(stderr, "unsupported Podoco ABI\n");
    return 1;
  }
  const char *version = podoco_version();
  if (version == NULL || strcmp(version, argv[1]) != 0 ||
      version != podoco_version()) {
    fprintf(stderr, "invalid Podoco version or borrowed lifetime\n");
    return 1;
  }
  printf("Podoco %s (C ABI %u)\n", version, (unsigned)podoco_abi_version());
  return 0;
}
