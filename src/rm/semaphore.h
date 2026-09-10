/* Private R4OS CPU semaphore bridge. Not an NVIDIA or platform ABI. */
#ifndef R4NV_SEMAPHORE_H
#define R4NV_SEMAPHORE_H
#include "nvtypes.h"

#define R4NV_SEMA_OK      0
#define R4NV_SEMA_RETRY   1
#define R4NV_SEMA_CONTEXT 2
#define R4NV_SEMA_INVALID 3
#define R4NV_SEMA_IRQ       1U
#define R4NV_SEMA_SLEEPABLE 2U

/* Live opaque CPU allocation, with a kernel-owned semaphore handle. Creation
 * and destruction require a sleepable driver context. A zero timeout is an
 * IRQ-safe try; NV_U64_MAX waits for a real permit, also during owner close.
 * The caller must quiesce all users before free. Failed frees retain ownership
 * and may be retried. No arbitrary-pointer or double-free validation promise. */
void *r4nv_semaphore_create(NvU32 initial);
NvS32 r4nv_semaphore_free(void *sema);
NvS32 r4nv_semaphore_acquire(void *sema, NvU64 timeout_ticks);
NvS32 r4nv_semaphore_release(void *sema);
NvU32 r4nv_semaphore_context_flags(void);
#endif
