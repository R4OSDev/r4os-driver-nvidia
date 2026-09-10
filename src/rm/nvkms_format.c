/* R4OS implementation; original NVKMS header supplies the public ABI. */
#include <nvidia-modeset-os-interface.h>
#include "format.h"

int nvkms_vsnprintf(char *data, size_t bytes, const char *format, va_list args)
{
    return r4nv_vformat(data, bytes, format, args);
}
int nvkms_snprintf(char *data, size_t bytes, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int result = nvkms_vsnprintf(data, bytes, format, args);
    va_end(args);
    return result;
}
