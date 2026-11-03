/* Disable Android bionic heap pointer tagging (TBI/MTE tags in the top byte)
   process-wide, so heap pointers stay < 2^53 when bun/opentui passes them to
   JS as numbers (otherwise: "Pointer exceeds safe integer range"). */
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>

extern int mallopt(int, int);

__attribute__((constructor)) static void disable_heap_tagging(void) {
  int r = mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE);
  if (getenv("NOHEAP_DEBUG"))
    fprintf(stderr, "NOHEAP: mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, NONE) = %d\n", r);
}
