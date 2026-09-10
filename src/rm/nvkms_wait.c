/* Original R4OS implementation against the unchanged NVKMS declarations. */
#include "nvidia-modeset-os-interface.h"
#include "wait.h"
#include "native_fault.h"
void nvkms_usleep(NvU64 usec)
{
    if (usec > NV_U64_MAX / 1000)
        r4nv_native_fault(R4NV_FAULT_WAIT, R4NV_WAIT_INVALID);
    NvS32 result = r4nv_wait_ns(usec * 1000, usec < 1000 ? R4NV_WAIT_BUSY : R4NV_WAIT_SLEEP);
    if (result != R4NV_WAIT_OK) r4nv_native_fault(R4NV_FAULT_WAIT, result);
}
void nvkms_yield(void)
{
    NvS32 result = r4nv_schedule(0);
    if (result != R4NV_WAIT_OK) r4nv_native_fault(R4NV_FAULT_YIELD, result);
}
