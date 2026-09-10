/* R4OS implementation; checked against the pinned NVKMS OS interface. */
#include <nvidia-modeset-os-interface.h>
#include "memory.h"

void *nvkms_alloc(size_t bytes, NvBool zero)
{
    void *memory = r4nv_heap_allocate(bytes == 0 ? 1 : bytes);
    if (memory != NULL && zero) r4nv_set(memory, 0, bytes);
    return memory;
}

void nvkms_free(void *memory, size_t bytes)
{
    /* The backing owner retains the actual size; the caller's size is not
     * used to reconstruct an allocation or select a different allocator. */
    (void)bytes;
    if (memory != NULL) r4nv_heap_free(memory);
}

void *nvkms_memcpy(void *destination, const void *source, size_t bytes)
{
    return r4nv_copy(destination, source, bytes);
}

void *nvkms_memset(void *destination, NvU8 value, size_t bytes)
{
    return r4nv_set(destination, value, bytes);
}

void *nvkms_memmove(void *destination, const void *source, size_t bytes)
{
    const NvUPtr dst = (NvUPtr)destination, src = (NvUPtr)source;
    if (dst == src || bytes == 0) return destination;
    if (dst < src || dst - src >= bytes) return r4nv_copy(destination, source, bytes);
    /* Backwards overlapping copy without setting DF, including when an
     * interrupt occurs between iterations. Unsigned addresses avoid C's
     * undefined ordering/subtraction of pointers to different objects. */
    NvU8 *d = destination;
    const NvU8 *s = source;
    while (bytes != 0) { --bytes; d[bytes] = s[bytes]; }
    return destination;
}

int nvkms_memcmp(const void *left, const void *right, size_t bytes)
{
    return r4nv_compare(left, right, bytes);
}

size_t nvkms_strlen(const char *text)
{
    return r4nv_length(text);
}

int nvkms_strcmp(const char *left, const char *right)
{
    return r4nv_string_compare(left, right);
}

char *nvkms_strncpy(char *destination, const char *source, size_t bytes)
{
    size_t i = 0;
    while (i < bytes && source[i] != '\0') { destination[i] = source[i]; ++i; }
    if (i < bytes) r4nv_set(destination + i, 0, bytes - i);
    return destination;
}
