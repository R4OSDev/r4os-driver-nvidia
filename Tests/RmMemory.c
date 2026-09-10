/* Bounded host acceptance of the actual R4OS RM/NVKMS memory adapters.
 * Host allocation/guard pages are test providers, never driver code. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <sys/mman.h>
#include <unistd.h>
#endif
#include <os-interface.h>
#include <nvidia-modeset-os-interface.h>
#include "memory.h"

static unsigned long long checks;
static void check(int condition, int line)
{
    ++checks;
    if (!condition) { fprintf(stderr, "RM memory check failed at line %d\n", line); exit(1); }
}
#define CHECK(condition) check(!!(condition), __LINE__)

struct allocation { unsigned char *base; size_t bytes; };
static struct allocation allocations[16];
static NvU64 last_request;
static unsigned int allocation_calls, live, frees;
static int fail_allocation;

void *r4nv_heap_allocate(NvU64 bytes)
{
    ++allocation_calls;
    last_request = bytes;
    CHECK(bytes != 0);
    if (fail_allocation || bytes > 4096) return NULL;
    for (size_t i = 0; i < 16; ++i) {
        if (allocations[i].base != NULL) continue;
        unsigned char *base = malloc((size_t)bytes + 32);
        CHECK(base != NULL && ((uintptr_t)base & 15) == 0);
        memset(base, 0xa5, (size_t)bytes + 32);
        allocations[i] = (struct allocation){base, (size_t)bytes};
        ++live;
        return base + 16;
    }
    return NULL;
}

void r4nv_heap_free(void *address)
{
    CHECK(address != NULL);
    for (size_t i = 0; i < 16; ++i) {
        if (allocations[i].base == NULL || allocations[i].base + 16 != address) continue;
        for (size_t k = 0; k < 16; ++k) {
            CHECK(allocations[i].base[k] == 0xa5);
            CHECK(allocations[i].base[16 + allocations[i].bytes + k] == 0xa5);
        }
        free(allocations[i].base);
        allocations[i] = (struct allocation){0};
        --live; ++frees;
        return;
    }
    CHECK(0); /* wrong or repeated release */
}

static void allocation_checks(void)
{
    unsigned int calls = allocation_calls;
    CHECK(os_alloc_mem(NULL, 64) == NV_ERR_INVALID_ARGUMENT);
    CHECK(allocation_calls == calls);
    os_free_mem(NULL); nvkms_free(NULL, 123);
    CHECK(frees == 0);
    for (size_t bytes = 0; bytes <= 1024; bytes += 17) {
        void *p = (void *)(uintptr_t)1;
        CHECK(os_alloc_mem(&p, bytes) == NV_OK && p != NULL);
        CHECK(last_request == (bytes == 0 ? 1 : bytes));
        memset(p, 0x37, bytes);
        os_free_mem(p);
        p = nvkms_alloc(bytes, NV_TRUE);
        CHECK(p != NULL && last_request == (bytes == 0 ? 1 : bytes));
        for (size_t i = 0; i < bytes; ++i) CHECK(((unsigned char *)p)[i] == 0);
        if (bytes == 0) CHECK(((unsigned char *)p)[0] == 0xa5);
        nvkms_free(p, bytes);
        p = nvkms_alloc(bytes, NV_FALSE);
        CHECK(p != NULL);
        for (size_t i = 0; i < bytes; ++i) CHECK(((unsigned char *)p)[i] == 0xa5);
        nvkms_free(p, bytes);
    }
    fail_allocation = 1;
    void *p = (void *)(uintptr_t)1;
    CHECK(os_alloc_mem(&p, 88) == NV_ERR_NO_MEMORY && p == NULL);
    CHECK(nvkms_alloc(88, NV_TRUE) == NULL);
    const NvU64 large[] = {0x100000007ULL, ~(NvU64)0};
    for (size_t i = 0; i < sizeof(large) / sizeof(large[0]); ++i) {
        p = (void *)(uintptr_t)1;
        CHECK(os_alloc_mem(&p, large[i]) == NV_ERR_NO_MEMORY && p == NULL);
        CHECK(last_request == large[i]);
        CHECK(nvkms_alloc((size_t)large[i], NV_FALSE) == NULL);
        CHECK(last_request == large[i]);
    }
    fail_allocation = 0;
    CHECK(live == 0);
}

static int sign(int value) { return (value > 0) - (value < 0); }

static void memory_checks(void)
{
    unsigned char source[320], actual[320], expected[320];
    for (size_t i = 0; i < sizeof(source); ++i) source[i] = (unsigned char)(i * 37 + 19);
    for (size_t bytes = 0; bytes <= 257; ++bytes) {
        for (size_t from = 0; from < 16; ++from) {
            for (size_t to = 0; to < 16; ++to) {
                memset(actual, 0x6b, sizeof(actual)); memcpy(expected, actual, sizeof(actual));
                memcpy(expected + to, source + from, bytes);
                CHECK(os_mem_copy(actual + to, source + from, (NvU32)bytes) == actual + to);
                CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
                memset(actual, 0x6b, sizeof(actual));
                CHECK(nvkms_memcpy(actual + to, source + from, bytes) == actual + to);
                CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
            }
            memset(actual, 0x6b, sizeof(actual)); memcpy(expected, actual, sizeof(actual));
            memset(expected + from, 0xe3, bytes);
            CHECK(os_mem_set(actual + from, 0xe3, (NvU32)bytes) == actual + from);
            CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
            memset(actual, 0x6b, sizeof(actual));
            CHECK(nvkms_memset(actual + from, 0xe3, bytes) == actual + from);
            CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
            CHECK(os_mem_cmp(actual, expected, (NvU32)sizeof(actual)) == 0);
            CHECK(nvkms_memcmp(actual, expected, sizeof(actual)) == 0);
            actual[from] ^= 0x80;
            CHECK(sign(os_mem_cmp(actual, expected, (NvU32)sizeof(actual))) == sign(memcmp(actual, expected, sizeof(actual))));
            CHECK(sign(nvkms_memcmp(actual, expected, sizeof(actual))) == sign(memcmp(actual, expected, sizeof(actual))));
        }
        for (size_t shift = 0; shift <= 17; ++shift) {
            memcpy(actual, source, sizeof(actual)); memcpy(expected, source, sizeof(expected));
            memmove(expected + shift, expected, bytes);
            CHECK(nvkms_memmove(actual + shift, actual, bytes) == actual + shift);
            CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
            memcpy(actual, source, sizeof(actual)); memcpy(expected, source, sizeof(expected));
            memmove(expected, expected + shift, bytes);
            CHECK(nvkms_memmove(actual, actual + shift, bytes) == actual);
            CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
        }
    }
}

static void string_checks(void)
{
    const char *strings[] = {"", "x", "R4OS NVIDIA", "\x80\xff", "\x7f"};
    char actual[64], expected[64];
    for (size_t i = 0; i < sizeof(strings) / sizeof(strings[0]); ++i) {
        const char *s = strings[i];
        CHECK(os_string_length(s) == strlen(s) && nvkms_strlen(s) == strlen(s));
        memset(actual, 0x41, sizeof(actual)); memcpy(expected, actual, sizeof(actual));
        strcpy(expected, s);
        CHECK(os_string_copy(actual, s) == actual);
        CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
        for (size_t n = 0; n <= sizeof(actual); ++n) {
            memset(actual, 0x41, sizeof(actual)); memcpy(expected, actual, sizeof(actual));
            strncpy(expected, s, n);
            CHECK(nvkms_strncpy(actual, s, n) == actual);
            CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
        }
        for (size_t j = 0; j < sizeof(strings) / sizeof(strings[0]); ++j) {
            CHECK(sign(os_string_compare(s, strings[j])) == sign(strcmp(s, strings[j])));
            CHECK(sign(nvkms_strcmp(s, strings[j])) == sign(strcmp(s, strings[j])));
        }
    }
}

struct guarded { unsigned char *base, *data; size_t page; };
static struct guarded guard_allocate(void)
{
    struct guarded g = {0};
#if defined(_WIN32)
    SYSTEM_INFO info;
    GetSystemInfo(&info); g.page = info.dwPageSize;
    g.base = VirtualAlloc(NULL, g.page * 3, MEM_RESERVE | MEM_COMMIT, PAGE_NOACCESS);
    CHECK(g.base != NULL);
    DWORD old_protection;
    CHECK(VirtualProtect(g.base + g.page, g.page, PAGE_READWRITE, &old_protection) != 0);
#else
    long page = sysconf(_SC_PAGESIZE);
    CHECK(page > 0); g.page = (size_t)page;
    void *base = mmap(NULL, g.page * 3, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(base != MAP_FAILED); g.base = base;
    CHECK(mprotect(g.base + g.page, g.page, PROT_READ | PROT_WRITE) == 0);
#endif
    g.data = g.base + g.page;
    return g;
}
static void guard_free(struct guarded g)
{
#if defined(_WIN32)
    CHECK(VirtualFree(g.base, 0, MEM_RELEASE) != 0);
#else
    CHECK(munmap(g.base, g.page * 3) == 0);
#endif
}

static void guard_checks(void)
{
    struct guarded source = guard_allocate(), destination = guard_allocate();
    CHECK(source.page == destination.page && source.page > 512);
    for (size_t n = 0; n <= 257; ++n) {
        for (int at_end = 0; at_end <= 1; ++at_end) {
            unsigned char *s = source.data + (at_end ? source.page - n : 0);
            unsigned char *d = destination.data + (at_end ? destination.page - n : 0);
            memset(s, 0x87, n);
            CHECK(nvkms_memset(d, 0x91, n) == d);
            CHECK(nvkms_memcpy(d, s, n) == d);
            CHECK(nvkms_memcmp(d, s, n) == 0);
            CHECK(os_mem_set(d, 0x93, (NvU32)n) == d);
            CHECK(os_mem_copy(d, s, (NvU32)n) == d);
            CHECK(os_mem_cmp(d, s, (NvU32)n) == 0);
            if (n != 0) {
                s[n - 1] = 0;
                CHECK(os_string_length((char *)s) == n - 1 && nvkms_strlen((char *)s) == n - 1);
                CHECK(os_string_copy((char *)d, (char *)s) == (char *)d);
                CHECK(os_string_compare((char *)d, (char *)s) == 0);
                CHECK(nvkms_strcmp((char *)d, (char *)s) == 0);
                CHECK(nvkms_strncpy((char *)d, (char *)s, n) == (char *)d);
                s[n - 1] = 0x87;
            }
            /* Exactly bounded strncpy also handles a source without NUL. */
            CHECK(nvkms_strncpy((char *)d, (char *)s, n) == (char *)d);
            CHECK(memcmp(d, s, n) == 0);
            CHECK(nvkms_memmove(d, s, n) == d);
            CHECK(memcmp(d, s, n) == 0);
        }
    }
    guard_free(source); guard_free(destination);
}

int main(void)
{
    CHECK(sizeof(NvU64) == 8 && sizeof(size_t) == 8);
    allocation_checks(); memory_checks(); string_checks(); guard_checks();
    CHECK(live == 0);
    printf("RM memory adapters: OK checks=%llu allocations=%u frees=%u live=%u guard-pages=active gpu=none\n", checks, allocation_calls, frees, live);
    return 0;
}
