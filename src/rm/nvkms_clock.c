/* R4OS-owned monotonic subset; declarations are the original NVIDIA ABI. */
#include "nvidia-modeset-os-interface.h"
#include "clock.h"

NvU64 nvkms_get_usec(void)
{
    NvU64 now = r4nv_clock_now_ns();
    return now == NV_U64_MAX ? NV_U64_MAX : now / 1000;
}
