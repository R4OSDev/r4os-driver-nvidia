/* R4OS-owned monotonic subset; declarations are the original NVIDIA ABI. */
#include "os-interface.h"
#include "clock.h"

NvU64 os_get_current_tick(void)
{
    return r4nv_clock_now_ns();
}

NvU64 os_get_current_tick_hr(void)
{
    return r4nv_clock_now_ns();
}

NvU64 os_get_tick_resolution(void)
{
    return r4nv_clock_resolution_ns();
}
