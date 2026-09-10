/* R4OS-owned monotonic clock bridge for the pinned RM/NVKMS source port. */
#ifndef R4NV_CLOCK_H
#define R4NV_CLOCK_H

#include <nvtypes.h>

/* Both ticks and the resolution use nanoseconds from the same monotonic
 * source. They are not CPU cycles, periodic timer counts or UTC time.
 * The bound R4D provider must latch a clock fault and reject further native
 * dispatch on UINT64_MAX. There is no target stub in the partial source link.
 * These value-only interfaces cannot themselves cancel an upstream loop.
 */
NvU64 r4nv_clock_now_ns(void);
NvU64 r4nv_clock_resolution_ns(void);

#endif
