/* Private native callback abort. R4D callers run these void APIs through
 * rm_native's abortable dedicated Tasks, with explicit owner cleanup after
 * all peers quiesce. A failed down never returns a fake permit. IRQ, kernel
 * critical sections and calls outside that boundary are ABI violations.
 * The separate full-RM partial link still leaves this provider unresolved. */
#ifndef R4NV_NATIVE_FAULT_H
#define R4NV_NATIVE_FAULT_H
#include "nvtypes.h"
#define R4NV_FAULT_SEMAPHORE_FREE 1U
#define R4NV_FAULT_SEMAPHORE_DOWN 2U
#define R4NV_FAULT_SEMAPHORE_UP   3U
void r4nv_native_fault(NvU32 operation, NvS32 result) __attribute__((noreturn));
#endif
