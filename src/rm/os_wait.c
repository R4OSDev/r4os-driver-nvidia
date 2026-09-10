/* Original R4OS implementation against the unchanged NVIDIA declarations. */
#include "os-interface.h"
#include "wait.h"
static NV_STATUS status(NvS32 value)
{
    switch (value) {
    case R4NV_WAIT_OK: return NV_OK;
    case R4NV_WAIT_INVALID: return NV_ERR_INVALID_ARGUMENT;
    case R4NV_WAIT_CONTEXT: return NV_ERR_ILLEGAL_ACTION;
    case R4NV_WAIT_CANCELLED: return NV_ERR_SIGNAL_PENDING;
    case R4NV_WAIT_DEADLINE: return NV_ERR_TIMEOUT;
    default: return NV_ERR_INVALID_STATE;
    }
}
NV_STATUS NV_API_CALL os_delay_us(NvU32 microseconds)
{
    return status(r4nv_wait_ns((NvU64)microseconds * 1000, R4NV_WAIT_BUSY));
}
NV_STATUS NV_API_CALL os_delay(NvU32 milliseconds)
{
    return status(r4nv_wait_ns((NvU64)milliseconds * 1000000, R4NV_WAIT_ADAPTIVE));
}
NV_STATUS NV_API_CALL os_schedule(void)
{
    return status(r4nv_schedule(1));
}
