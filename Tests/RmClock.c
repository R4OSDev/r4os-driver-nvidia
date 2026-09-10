/* Original R4OS test; executes the real adapters, without any GPU access. */
#include <stdio.h>
#include <stdlib.h>
#include "os-interface.h"
#include "nvidia-modeset-os-interface.h"
#include "clock.h"

static NvU64 instant, quantum, reads, resolution_reads;
NvU64 r4nv_clock_now_ns(void) { ++reads; return instant; }
NvU64 r4nv_clock_resolution_ns(void) { ++resolution_reads; return quantum; }

static void require(int predicate)
{
    if (!predicate) { fputs("RM clock adapters: FAILED\n", stderr); exit(1); }
}

int main(void)
{
    const NvU64 points[] = { 0, 1, 999, 1000, 1001, 999999999, 1000000000,
        0xffffffffULL, 0x100000001ULL, 0x1000000000000000ULL,
        NV_U64_MAX - 1, NV_U64_MAX };
    const NvU64 quanta[] = { 1, 40, 1000, 10000001, NV_U64_MAX };
    size_t checks = 0;
    for (size_t i = 0; i < sizeof(points) / sizeof(points[0]); ++i) {
        instant = points[i];
        require(os_get_current_tick() == instant);
        require(os_get_current_tick_hr() == instant);
        require(nvkms_get_usec() == (instant == NV_U64_MAX ? NV_U64_MAX : instant / 1000));
        checks += 3;
    }
    for (size_t i = 0; i < sizeof(quanta) / sizeof(quanta[0]); ++i) {
        quantum = quanta[i];
        require(os_get_tick_resolution() == quantum);
        ++checks;
    }
    require(reads == 36 && resolution_reads == 5);
    printf("RM clock adapters: OK checks=%zu reads=%llu resolution-reads=%llu units=ns/us gpu=none\n",
           checks + 1, (unsigned long long)reads, (unsigned long long)resolution_reads);
    return 0;
}
