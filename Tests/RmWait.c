/* Hosted fault fixture only. Target objects always use the real R4D provider. */
#include <stdio.h>
#include <stdlib.h>
#include <setjmp.h>
#include "os-interface.h"
#include "nvidia-modeset-os-interface.h"
#include "wait.h"
#include "native_fault.h"
static NvU64 duration, scheduled;
static NvU32 mode, operation;
static NvS32 result, fault_result;
static unsigned checks, calls, faults;
static jmp_buf boundary;
NvS32 r4nv_wait_ns(NvU64 ns, NvU32 value) { ++calls; duration = ns; mode = value; return result; }
NvS32 r4nv_schedule(NvU64 ticks) { ++calls; scheduled = ticks; return result; }
void r4nv_native_fault(NvU32 op, NvS32 value) { ++faults; operation = op; fault_result = value; longjmp(boundary, 1); }
static void require(int predicate)
{
    ++checks;
    if (!predicate) { fprintf(stderr, "RM wait adapters: FAILED check=%u\n", checks); exit(1); }
}
int main(void)
{
    const NV_STATUS expected[] = { NV_OK, NV_ERR_INVALID_ARGUMENT, NV_ERR_ILLEGAL_ACTION, NV_ERR_SIGNAL_PENDING, NV_ERR_TIMEOUT, NV_ERR_INVALID_STATE, NV_ERR_INVALID_STATE };
    for (result = 0; result < 7; ++result) {
        require(os_delay_us(NV_U32_MAX) == expected[result]);
        require(duration == (NvU64)NV_U32_MAX * 1000 && mode == R4NV_WAIT_BUSY);
        require(os_delay(NV_U32_MAX) == expected[result]);
        require(duration == (NvU64)NV_U32_MAX * 1000000 && mode == R4NV_WAIT_ADAPTIVE);
        require(os_schedule() == expected[result] && scheduled == 1);
    }
    result = 0;
    const NvU64 values[] = { 0, 1, 999, 1000, 4100000, 0xffffffffULL, 0x100000001ULL, NV_U64_MAX / 1000 };
    for (unsigned i = 0; i < sizeof(values) / sizeof(values[0]); ++i) {
        nvkms_usleep(values[i]);
        require(duration == values[i] * 1000 && mode == (values[i] < 1000 ? R4NV_WAIT_BUSY : R4NV_WAIT_SLEEP));
    }
    nvkms_yield();
    require(scheduled == 0);
    for (result = 1; result < 7; ++result) {
        if (setjmp(boundary) == 0) { nvkms_usleep(1001); require(0); }
        require(operation == R4NV_FAULT_WAIT && fault_result == result);
        if (setjmp(boundary) == 0) { nvkms_yield(); require(0); }
        require(operation == R4NV_FAULT_YIELD && fault_result == result);
    }
    unsigned before = calls;
    if (setjmp(boundary) == 0) { nvkms_usleep(NV_U64_MAX / 1000 + 1); require(0); }
    require(operation == R4NV_FAULT_WAIT && fault_result == R4NV_WAIT_INVALID && calls == before);
    require(faults == 13);
    printf("RM wait adapters: OK checks=%u calls=%u faults=%u width=64 status=preserved gpu=none\n", checks, calls, faults);
    return 0;
}
