/* Original R4OS diagnostic using the five unchanged NVIDIA wait declarations. */
#include "os-interface.h"
#include "nvidia-modeset-os-interface.h"
#include "clock.h"
#define CHECK(condition) do { if (!(condition)) return -__LINE__; } while (0)
typedef struct { NvU32 milliseconds; NvU32 expected; NvU32 returned; NvU32 observed; } WaitProbe;
NvS32 r4nv_wait_probe_healthy(NvUPtr context)
{
    (void)context;
    NvU64 start = r4nv_clock_now_ns();
    CHECK(os_delay_us(250) == NV_OK);
    CHECK(r4nv_clock_now_ns() - start >= 250000);
    start = r4nv_clock_now_ns();
    CHECK(os_delay(25) == NV_OK);
    CHECK(r4nv_clock_now_ns() - start >= 25000000);
    start = r4nv_clock_now_ns();
    nvkms_usleep(250);
    CHECK(r4nv_clock_now_ns() - start >= 250000);
    // Cross the upstream Linux implementation's 12-bit millisecond wrap.
    start = r4nv_clock_now_ns();
    nvkms_usleep(4100000);
    CHECK(r4nv_clock_now_ns() - start >= (NvU64)4100000000);
    CHECK(os_schedule() == NV_OK);
    nvkms_yield();
    return 0;
}
NvS32 r4nv_wait_probe_delay(NvUPtr context)
{
    WaitProbe *s = (WaitProbe *)context;
    NvU32 result = os_delay(s->milliseconds);
    s->observed = result;
    __atomic_store_n(&s->returned, 1, __ATOMIC_RELEASE);
    CHECK(result == s->expected);
    return 0;
}
