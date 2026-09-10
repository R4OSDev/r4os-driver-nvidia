/* Explicit CPU diagnostic; state stays alive until every native Task retires. */
#ifndef R4NV_SEMAPHORE_PROBE_H
#define R4NV_SEMAPHORE_PROBE_H
#include "nvtypes.h"
typedef struct {
    void *memory;
    void *semaphore;
    NvU32 after_fault;
    NvU32 after_wait;
    NvU32 permit_sent;
} R4NvSemaphoreProbe;
NvS32 r4nv_semaphore_probe_healthy(NvUPtr context);
NvS32 r4nv_semaphore_probe_setup(NvUPtr context);
NvS32 r4nv_semaphore_probe_wait(NvUPtr context);
NvS32 r4nv_semaphore_probe_fault(NvUPtr context);
NvS32 r4nv_semaphore_probe_permit(NvUPtr context);
NvS32 r4nv_semaphore_probe_cleanup(NvUPtr context);
#endif
