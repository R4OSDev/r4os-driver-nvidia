/* Private R4OS monotonic wait bridge; not an NVIDIA or public platform ABI. */
#ifndef R4NV_WAIT_H
#define R4NV_WAIT_H
#include "nvtypes.h"
#define R4NV_WAIT_OK 0
#define R4NV_WAIT_INVALID 1
#define R4NV_WAIT_CONTEXT 2
#define R4NV_WAIT_CANCELLED 3
#define R4NV_WAIT_DEADLINE 4
#define R4NV_WAIT_CLOCK 5
#define R4NV_WAIT_BUSY 0U
#define R4NV_WAIT_ADAPTIVE 1U
#define R4NV_WAIT_SLEEP 2U
/* Success requires the actual monotonic interval. Scheduler wake, stop,
 * clock loss or the enclosing invocation deadline cannot fake completion. */
NvS32 r4nv_wait_ns(NvU64 nanoseconds, NvU32 mode);
NvS32 r4nv_schedule(NvU64 ticks);
#endif
