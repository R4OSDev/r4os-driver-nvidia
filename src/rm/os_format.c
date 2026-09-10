/* R4OS implementation; original RM header supplies the public ABI. */
#include <os-interface.h>
#include "format.h"

NvS32 NV_API_CALL os_vsnprintf(char *data, NvU32 bytes, const char *format, va_list args)
{
    return r4nv_vformat(data, bytes, format, args);
}
NvS32 NV_API_CALL os_snprintf(char *data, NvU32 bytes, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    int result = os_vsnprintf(data, bytes, format, args);
    va_end(args);
    return result;
}
