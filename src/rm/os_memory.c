/* R4OS implementation; signatures are checked against the pinned RM header. */
#include <os-interface.h>
#include "memory.h"

NV_STATUS NV_API_CALL os_alloc_mem(void **address, NvU64 bytes)
{
    if (address == NULL) return NV_ERR_INVALID_ARGUMENT;
    *address = NULL;
    *address = r4nv_heap_allocate(bytes == 0 ? 1 : bytes);
    return *address == NULL ? NV_ERR_NO_MEMORY : NV_OK;
}

void NV_API_CALL os_free_mem(void *address)
{
    if (address != NULL) r4nv_heap_free(address);
}

void *NV_API_CALL os_mem_copy(void *destination, const void *source, NvU32 bytes)
{
    return r4nv_copy(destination, source, bytes);
}

void *NV_API_CALL os_mem_set(void *destination, NvU8 value, NvU32 bytes)
{
    return r4nv_set(destination, value, bytes);
}

NvS32 NV_API_CALL os_mem_cmp(const NvU8 *left, const NvU8 *right, NvU32 bytes)
{
    return r4nv_compare(left, right, bytes);
}

char *NV_API_CALL os_string_copy(char *destination, const char *source)
{
    char *result = destination;
    do { *destination++ = *source; } while (*source++ != '\0');
    return result;
}

NvU32 NV_API_CALL os_string_length(const char *text)
{
    /* RM's ABI deliberately returns NvU32, unlike NVKMS's size_t. */
    return (NvU32)r4nv_length(text);
}

NvS32 NV_API_CALL os_string_compare(const char *left, const char *right)
{
    return r4nv_string_compare(left, right);
}
