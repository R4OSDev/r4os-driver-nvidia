/* Original R4OS diagnostic using all 16 original-header semaphore adapters. */
#include "os-interface.h"
#include "nvidia-modeset-os-interface.h"
#include "semaphore_probe.h"
#define CHECK(condition) do { if (!(condition)) return -__LINE__; } while (0)

NvS32 r4nv_semaphore_probe_healthy(NvUPtr context)
{
    R4NvSemaphoreProbe *s = (R4NvSemaphoreProbe *)context;
    CHECK(os_semaphore_may_sleep() && !os_is_isr());
    CHECK(os_alloc_mutex(NULL) == NV_ERR_INVALID_ARGUMENT);
    CHECK(os_alloc_mutex(&s->semaphore) == NV_OK);
    CHECK(os_cond_acquire_mutex(s->semaphore) == NV_OK);
    CHECK(os_cond_acquire_mutex(s->semaphore) == NV_ERR_TIMEOUT_RETRY);
    os_release_mutex(s->semaphore);
    CHECK(os_acquire_mutex(s->semaphore) == NV_OK);
    os_release_mutex(s->semaphore);
    os_free_mutex(s->semaphore);
    s->semaphore = NULL;

    s->semaphore = os_alloc_semaphore(2);
    CHECK(s->semaphore != NULL);
    CHECK(os_cond_acquire_semaphore(s->semaphore) == NV_OK);
    CHECK(os_acquire_semaphore(s->semaphore) == NV_OK);
    CHECK(os_cond_acquire_semaphore(s->semaphore) == NV_ERR_TIMEOUT_RETRY);
    CHECK(os_release_semaphore(s->semaphore) == NV_OK);
    CHECK(os_acquire_semaphore(s->semaphore) == NV_OK);
    os_free_semaphore(s->semaphore);
    s->semaphore = NULL;

    s->semaphore = nvkms_sema_alloc();
    CHECK(s->semaphore != NULL);
    nvkms_sema_down(s->semaphore);
    nvkms_sema_up(s->semaphore);
    nvkms_sema_down(s->semaphore);
    nvkms_sema_up(s->semaphore);
    nvkms_sema_free(s->semaphore);
    s->semaphore = NULL;
    return 0;
}
NvS32 r4nv_semaphore_probe_setup(NvUPtr context)
{
    R4NvSemaphoreProbe *s = (R4NvSemaphoreProbe *)context;
    CHECK(os_alloc_mem(&s->memory, 97) == NV_OK);
    for (NvU32 i = 0; i < 97; ++i) ((NvU8 *)s->memory)[i] = (NvU8)(i ^ 0x79);
    s->semaphore = os_alloc_semaphore(0);
    CHECK(s->semaphore != NULL);
    return 0;
}
NvS32 r4nv_semaphore_probe_wait(NvUPtr context)
{
    R4NvSemaphoreProbe *s = (R4NvSemaphoreProbe *)context;
    nvkms_sema_down(s->semaphore);
    __atomic_store_n(&s->after_wait, 1, __ATOMIC_RELEASE);
    return 0;
}
NvS32 r4nv_semaphore_probe_fault(NvUPtr context)
{
    R4NvSemaphoreProbe *s = (R4NvSemaphoreProbe *)context;
    // A real enrolled waiter makes the kernel reject destroy with Busy. The
    // void C API must leave this callback, retaining both live allocations.
    nvkms_sema_free(s->semaphore);
    __atomic_store_n(&s->after_fault, 1, __ATOMIC_RELEASE);
    return -1;
}
NvS32 r4nv_semaphore_probe_permit(NvUPtr context)
{
    R4NvSemaphoreProbe *s = (R4NvSemaphoreProbe *)context;
    nvkms_sema_up(s->semaphore);
    __atomic_store_n(&s->permit_sent, 1, __ATOMIC_RELEASE);
    return 0;
}
NvS32 r4nv_semaphore_probe_cleanup(NvUPtr context)
{
    R4NvSemaphoreProbe *s = (R4NvSemaphoreProbe *)context;
    for (NvU32 i = 0; i < 97; ++i) CHECK(((NvU8 *)s->memory)[i] == (NvU8)(i ^ 0x79));
    nvkms_sema_free(s->semaphore);
    s->semaphore = NULL;
    // The native owner frees memory after this callback retires, using the
    // status-bearing private heap operation so a failed free stays retryable.
    return 0;
}
