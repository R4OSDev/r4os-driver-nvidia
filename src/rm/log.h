/* Private CPU-only adapter; each call publishes one bounded driver record. */
#ifndef R4NV_LOG_H
#define R4NV_LOG_H
#include <nvtypes.h>
#define R4NV_LOG_INFO 0U
#define R4NV_LOG_WARN 1U
#define R4NV_LOG_ERROR 2U
#define R4NV_LOG_BYTES 512U
NvS32 r4nv_log(NvU32 severity, const char *text);

/* Preserve an explicit truncation marker inside the kernel's 512-byte record.
 * No shared scratch buffer and no allocator are used. */
static inline void r4nv_log_finish(char *buffer, int formatted)
{
    if (formatted < 0) {
        const char message[] = "NVIDIA native log: invalid or unsupported format";
        for (unsigned i = 0; i < sizeof(message); ++i) buffer[i] = message[i];
    } else if ((unsigned)formatted >= R4NV_LOG_BYTES) {
        const char marker[] = " [truncated]";
        unsigned start = R4NV_LOG_BYTES - sizeof(marker);
        for (unsigned i = 0; i < sizeof(marker); ++i) buffer[start + i] = marker[i];
    }
}
#endif
