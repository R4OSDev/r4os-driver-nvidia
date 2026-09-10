/* Original R4OS implementation, compiled against pinned original RM headers. */
#include "os-interface.h"
#include <stddef.h>
#include "semaphore.h"
#include "native_fault.h"

static NV_STATUS status(NvS32 result)
{
    switch (result) {
    case R4NV_SEMA_OK: return NV_OK;
    case R4NV_SEMA_RETRY: return NV_ERR_TIMEOUT_RETRY;
    case R4NV_SEMA_CONTEXT: return NV_ERR_INVALID_REQUEST;
    default: return NV_ERR_INVALID_STATE;
    }
}

NvBool NV_API_CALL os_semaphore_may_sleep(void)
{
    return !!(r4nv_semaphore_context_flags() & R4NV_SEMA_SLEEPABLE);
}
NvBool NV_API_CALL os_is_isr(void)
{
    return !!(r4nv_semaphore_context_flags() & R4NV_SEMA_IRQ);
}
NV_STATUS NV_API_CALL os_alloc_mutex(void **out)
{
    if (out == NULL) return NV_ERR_INVALID_ARGUMENT;
    *out = r4nv_semaphore_create(1);
    return *out != NULL ? NV_OK : NV_ERR_NO_MEMORY;
}
void *NV_API_CALL os_alloc_semaphore(NvU32 initial)
{
    return r4nv_semaphore_create(initial);
}
void NV_API_CALL os_free_semaphore(void *sema)
{
    NvS32 result = r4nv_semaphore_free(sema);
    if (result != R4NV_SEMA_OK)
        r4nv_native_fault(R4NV_FAULT_SEMAPHORE_FREE, result);
}
void NV_API_CALL os_free_mutex(void *sema)
{
    os_free_semaphore(sema);
}
NV_STATUS NV_API_CALL os_acquire_semaphore(void *sema)
{
    if (!os_semaphore_may_sleep()) return NV_ERR_INVALID_REQUEST;
    return status(r4nv_semaphore_acquire(sema, NV_U64_MAX));
}
NV_STATUS NV_API_CALL os_acquire_mutex(void *sema)
{
    return os_acquire_semaphore(sema);
}
NV_STATUS NV_API_CALL os_cond_acquire_semaphore(void *sema)
{
    return status(r4nv_semaphore_acquire(sema, 0));
}
NV_STATUS NV_API_CALL os_cond_acquire_mutex(void *sema)
{
    /* Upstream requires a sleepable context even for its conditional mutex. */
    if (!os_semaphore_may_sleep()) return NV_ERR_INVALID_REQUEST;
    return os_cond_acquire_semaphore(sema);
}
NV_STATUS NV_API_CALL os_release_semaphore(void *sema)
{
    return status(r4nv_semaphore_release(sema));
}
void NV_API_CALL os_release_mutex(void *sema)
{
    NvS32 result = r4nv_semaphore_release(sema);
    if (result != R4NV_SEMA_OK)
        r4nv_native_fault(R4NV_FAULT_SEMAPHORE_UP, result);
}
