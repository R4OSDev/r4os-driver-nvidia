/* Original R4OS implementation, compiled against pinned NVKMS declarations. */
#include "nvidia-modeset-os-interface.h"
#include "semaphore.h"
#include "native_fault.h"

nvkms_sema_handle_t *nvkms_sema_alloc(void)
{
    return r4nv_semaphore_create(1);
}
void nvkms_sema_free(nvkms_sema_handle_t *sema)
{
    NvS32 result = r4nv_semaphore_free(sema);
    if (result != R4NV_SEMA_OK)
        r4nv_native_fault(R4NV_FAULT_SEMAPHORE_FREE, result);
}
void nvkms_sema_down(nvkms_sema_handle_t *sema)
{
    NvS32 result = r4nv_semaphore_acquire(sema, NV_U64_MAX);
    if (result != R4NV_SEMA_OK)
        r4nv_native_fault(R4NV_FAULT_SEMAPHORE_DOWN, result);
}
void nvkms_sema_up(nvkms_sema_handle_t *sema)
{
    NvS32 result = r4nv_semaphore_release(sema);
    if (result != R4NV_SEMA_OK)
        r4nv_native_fault(R4NV_FAULT_SEMAPHORE_UP, result);
}
