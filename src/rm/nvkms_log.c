/* R4OS log transport; each message remains one driver-owned record. */
#include <nvidia-modeset-os-interface.h>
#include "log.h"

void nvkms_log(const int level, const char *gpu_prefix, const char *message)
{
    char buffer[R4NV_LOG_BYTES];
    int count = nvkms_snprintf(buffer, sizeof(buffer), "NVIDIA modeset: %s%s",
                              gpu_prefix == NULL ? "" : gpu_prefix,
                              message == NULL ? "(null)" : message);
    r4nv_log_finish(buffer, count);
    NvU32 severity = R4NV_LOG_INFO;
    if (level == NVKMS_LOG_LEVEL_WARN) severity = R4NV_LOG_WARN;
    if (level == NVKMS_LOG_LEVEL_ERROR || count < 0) severity = R4NV_LOG_ERROR;
    (void)r4nv_log(severity, buffer);
}
