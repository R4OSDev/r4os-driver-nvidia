/* Execute the actual freestanding C adapters with a hosted provider fixture.
 * This validates ABI, context rules, status mapping and nonreturning failures;
 * real kernel waiting/lifecycle is tested separately in the SMP4 guest. */
#include <stdio.h>
#include <stdlib.h>
#include <setjmp.h>
#include "os-interface.h"
#include "nvidia-modeset-os-interface.h"
#include "semaphore.h"
#include "native_fault.h"

static struct { NvU32 count; int live; } record;
static NvU32 flags, initial, fault_operation;
static NvS32 forced_acquire, forced_release, forced_free, fault_result;
static NvU64 timeout;
static unsigned checks, creates, acquires, releases, frees, faults;
static int allocation_failure, fault_expected;
static jmp_buf fault_boundary;
#define CHECK(p) do { ++checks; if (!(p)) { fprintf(stderr, "RM semaphore adapters: FAILED line=%d\n", __LINE__); exit(1); } } while (0)

void *r4nv_semaphore_create(NvU32 value)
{
    ++creates;
    initial = value;
    if (allocation_failure) return NULL;
    CHECK(!record.live);
    record.count = value;
    record.live = 1;
    return &record;
}
NvS32 r4nv_semaphore_free(void *pointer)
{
    ++frees;
    if (pointer == NULL) return R4NV_SEMA_OK;
    CHECK(pointer == &record && record.live);
    if (forced_free) return forced_free;
    record.live = 0;
    return R4NV_SEMA_OK;
}
NvS32 r4nv_semaphore_acquire(void *pointer, NvU64 ticks)
{
    ++acquires;
    timeout = ticks;
    CHECK(pointer == &record && record.live);
    if (forced_acquire) return forced_acquire;
    if (ticks && !(flags & R4NV_SEMA_SLEEPABLE)) return R4NV_SEMA_CONTEXT;
    if (!record.count) return R4NV_SEMA_RETRY;
    --record.count;
    return R4NV_SEMA_OK;
}
NvS32 r4nv_semaphore_release(void *pointer)
{
    ++releases;
    CHECK(pointer == &record && record.live);
    if (forced_release) return forced_release;
    if (record.count == NV_U32_MAX) return R4NV_SEMA_INVALID;
    ++record.count;
    return R4NV_SEMA_OK;
}
NvU32 r4nv_semaphore_context_flags(void) { return flags; }
void r4nv_native_fault(NvU32 operation, NvS32 result)
{
    CHECK(fault_expected);
    ++faults;
    fault_operation = operation;
    fault_result = result;
    /* Hosted fixture only: the target has no implementation of this required
     * native boundary yet. Never substitute this fixture into a R4D. */
    longjmp(fault_boundary, 1);
}
#define EXPECT_FAULT(call, operation, result) do { \
    fault_expected = 1; \
    if (setjmp(fault_boundary) == 0) { call; CHECK(0); } \
    fault_expected = 0; \
    CHECK(fault_operation == (operation) && fault_result == (result)); \
} while (0)

int main(void)
{
    void *pointer = NULL;
    flags = R4NV_SEMA_SLEEPABLE;
    CHECK(os_alloc_mutex(NULL) == NV_ERR_INVALID_ARGUMENT && creates == 0);
    allocation_failure = 1;
    pointer = &record;
    CHECK(os_alloc_mutex(&pointer) == NV_ERR_NO_MEMORY && pointer == NULL);
    CHECK(os_alloc_semaphore(7) == NULL && initial == 7);
    CHECK(nvkms_sema_alloc() == NULL && initial == 1);
    allocation_failure = 0;

    CHECK(os_alloc_mutex(&pointer) == NV_OK && pointer == &record && initial == 1);
    CHECK(os_acquire_mutex(pointer) == NV_OK && timeout == NV_U64_MAX && record.count == 0);
    CHECK(os_cond_acquire_mutex(pointer) == NV_ERR_TIMEOUT_RETRY && timeout == 0);
    os_release_mutex(pointer);
    CHECK(record.count == 1);
    for (NvU32 context = 0; context != 4; ++context) {
        flags = context;
        CHECK(os_semaphore_may_sleep() == !!(context & R4NV_SEMA_SLEEPABLE));
        CHECK(os_is_isr() == !!(context & R4NV_SEMA_IRQ));
        if (!(context & R4NV_SEMA_SLEEPABLE)) {
            unsigned before = acquires;
            CHECK(os_acquire_mutex(pointer) == NV_ERR_INVALID_REQUEST);
            CHECK(os_cond_acquire_mutex(pointer) == NV_ERR_INVALID_REQUEST);
            CHECK(os_acquire_semaphore(pointer) == NV_ERR_INVALID_REQUEST && acquires == before);
        }
        /* Conditional semaphore acquisition remains legal in IRQ context. */
        CHECK(os_cond_acquire_semaphore(pointer) == NV_OK && record.count == 0 && timeout == 0);
        CHECK(os_release_semaphore(pointer) == NV_OK && record.count == 1);
    }
    flags = R4NV_SEMA_SLEEPABLE;
    for (NvS32 code = 1; code <= 4; ++code) {
        const NV_STATUS expected = code == R4NV_SEMA_RETRY ? NV_ERR_TIMEOUT_RETRY :
            code == R4NV_SEMA_CONTEXT ? NV_ERR_INVALID_REQUEST : NV_ERR_INVALID_STATE;
        forced_acquire = code;
        CHECK(os_acquire_semaphore(pointer) == expected && timeout == NV_U64_MAX && record.count == 1);
        CHECK(os_cond_acquire_mutex(pointer) == expected && timeout == 0);
        forced_release = code;
        CHECK(os_release_semaphore(pointer) == expected && record.count == 1);
        EXPECT_FAULT(os_release_mutex(pointer), R4NV_FAULT_SEMAPHORE_UP, code);
        forced_free = code;
        EXPECT_FAULT(os_free_mutex(pointer), R4NV_FAULT_SEMAPHORE_FREE, code);
        EXPECT_FAULT(os_free_semaphore(pointer), R4NV_FAULT_SEMAPHORE_FREE, code);
        CHECK(record.live);
    }
    forced_acquire = forced_release = forced_free = 0;
    os_free_mutex(pointer);
    CHECK(!record.live);
    os_free_mutex(NULL);
    os_free_semaphore(NULL);

    pointer = os_alloc_semaphore(NV_U32_MAX);
    CHECK(pointer == &record && initial == NV_U32_MAX && record.count == NV_U32_MAX);
    CHECK(os_release_semaphore(pointer) == NV_ERR_INVALID_STATE && record.count == NV_U32_MAX);
    CHECK(os_acquire_semaphore(pointer) == NV_OK && record.count == NV_U32_MAX - 1 && timeout == NV_U64_MAX);
    os_free_semaphore(pointer);
    pointer = os_alloc_semaphore(0);
    CHECK(pointer == &record && record.count == 0);
    CHECK(os_cond_acquire_semaphore(pointer) == NV_ERR_TIMEOUT_RETRY);
    CHECK(os_release_semaphore(pointer) == NV_OK);
    CHECK(os_cond_acquire_semaphore(pointer) == NV_OK);
    os_free_semaphore(pointer);

    nvkms_sema_handle_t *sema = nvkms_sema_alloc();
    CHECK((void *)sema == &record && record.count == 1);
    nvkms_sema_down(sema);
    CHECK(record.count == 0 && timeout == NV_U64_MAX);
    nvkms_sema_up(sema);
    CHECK(record.count == 1);
    for (NvS32 code = 1; code <= 4; ++code) {
        forced_acquire = forced_release = forced_free = code;
        EXPECT_FAULT(nvkms_sema_down(sema), R4NV_FAULT_SEMAPHORE_DOWN, code);
        CHECK(record.count == 1 && timeout == NV_U64_MAX);
        EXPECT_FAULT(nvkms_sema_up(sema), R4NV_FAULT_SEMAPHORE_UP, code);
        EXPECT_FAULT(nvkms_sema_free(sema), R4NV_FAULT_SEMAPHORE_FREE, code);
        CHECK(record.live && record.count == 1);
    }
    forced_acquire = forced_release = forced_free = 0;
    flags = R4NV_SEMA_IRQ;
    EXPECT_FAULT(nvkms_sema_down(sema), R4NV_FAULT_SEMAPHORE_DOWN, R4NV_SEMA_CONTEXT);
    CHECK(record.count == 1);
    flags = R4NV_SEMA_SLEEPABLE;
    nvkms_sema_free(sema);
    nvkms_sema_free(NULL);
    CHECK(!record.live && faults == 25);
    printf("RM semaphore adapters: OK checks=%u creates=%u acquires=%u releases=%u frees=%u faults=%u live=0 gpu=none\n",
        checks, creates, acquires, releases, frees, faults);
    return 0;
}
