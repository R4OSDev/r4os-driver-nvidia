/* R4OS-owned CPU memory bridge for the pinned RM/NVKMS source port. */
#ifndef R4NV_MEMORY_H
#define R4NV_MEMORY_H

#include <stddef.h>
#include <nvtypes.h>

#if !defined(__x86_64__)
#error "R4OS RM memory adapters require x86_64"
#endif

/* Private driver imports, not a public DriverApi or host libc dependency.
 * The eventual R4OS provider must return resident, 16-byte aligned CPU RAM
 * belonging to the current driver, or NULL. Zero is normalized by the caller.
 * It must reject new allocations during close and retain failed backing
 * release until completion. IRQ admission, synchronization and ownership are
 * provider responsibilities; these adapters grant no DMA or MMIO access.
 * There is deliberately no default/success-stub provider in the source port.
 */
void *r4nv_heap_allocate(NvU64 bytes);
void r4nv_heap_free(void *address);

/* Integer-register copies avoid the RM gcc_helper.c -> os_mem_copy ->
 * compiler-generated memcpy recursion. No SIMD state or host runtime is
 * required. The x86_64 C ABI supplies DF=0; these routines never change it.
 * They access exactly the requested CPU-memory span, including unaligned
 * tails. Device register accesses remain a separate platform operation.
 */
static inline void *r4nv_copy(void *destination, const void *source, size_t bytes)
{
    void *result = destination;
    size_t words = bytes / 8;
    size_t tail = bytes % 8;
    __asm__ volatile ("rep movsq" : "+D"(destination), "+S"(source), "+c"(words) : : "memory");
    __asm__ volatile ("rep movsb" : "+D"(destination), "+S"(source), "+c"(tail) : : "memory");
    return result;
}

static inline void *r4nv_set(void *destination, NvU8 value, size_t bytes)
{
    void *result = destination;
    size_t words = bytes / 8;
    size_t tail = bytes % 8;
    NvU64 pattern = (NvU64)value * 0x0101010101010101ULL;
    __asm__ volatile ("rep stosq" : "+D"(destination), "+c"(words) : "a"(pattern) : "memory");
    __asm__ volatile ("rep stosb" : "+D"(destination), "+c"(tail) : "a"(value) : "memory");
    return result;
}

static inline int r4nv_compare(const void *left, const void *right, size_t bytes)
{
    const NvU8 *a = left, *b = right;
    for (size_t i = 0; i < bytes; ++i) {
        if (a[i] != b[i]) return (int)a[i] - (int)b[i];
    }
    return 0;
}

static inline size_t r4nv_length(const char *text)
{
    size_t length = 0;
    while (text[length] != '\0') ++length;
    return length;
}

static inline int r4nv_string_compare(const char *left, const char *right)
{
    const NvU8 *a = (const NvU8 *)left, *b = (const NvU8 *)right;
    while (*a != 0 && *a == *b) { ++a; ++b; }
    return (int)*a - (int)*b;
}

#endif
