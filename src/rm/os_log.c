/* R4OS log transport for the pinned original RM ABI. */
#include <os-interface.h>
#include "log.h"

static NvU32 debug_level = 0xffffffffU;
static NvU32 severity(NvU32 level)
{
    if (level >= NV_DBG_ERRORS || level == NV_DBG_USERERRORS) return R4NV_LOG_ERROR;
    if (level == NV_DBG_WARNINGS) return R4NV_LOG_WARN;
    return R4NV_LOG_INFO;
}
void NV_API_CALL os_dbg_set_level(NvU32 value)
{
    __atomic_store_n(&debug_level, value, __ATOMIC_RELEASE);
}
int NV_API_CALL nv_printf(NvU32 level, const char *format, ...)
{
    /* Preserve NVIDIA's threshold encoding, including a filtered return of 0. */
    if (level < ((__atomic_load_n(&debug_level, __ATOMIC_ACQUIRE) >> 4) & 3U)) return 0;
    char buffer[R4NV_LOG_BYTES];
    va_list args;
    va_start(args, format);
    int count = os_vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    r4nv_log_finish(buffer, count);
    int logged = r4nv_log(count < 0 ? R4NV_LOG_ERROR : severity(level), buffer);
    if (count < 0 || logged < 0) return -1;
    /* Logging returns bytes actually submitted, unlike snprintf's length. */
    return logged;
}
void NV_API_CALL out_string(const char *text)
{
    (void)r4nv_log(R4NV_LOG_INFO, text);
}
void NV_API_CALL os_log_error(const char *format, va_list args)
{
    char buffer[R4NV_LOG_BYTES];
    int count = os_vsnprintf(buffer, sizeof(buffer), format, args);
    r4nv_log_finish(buffer, count);
    (void)r4nv_log(R4NV_LOG_ERROR, buffer);
}
