/* Host-only differential and guard-page checks of the exact freestanding
 * formatting/log C objects. The fixture sink is never linked into NVIDIA.R4D. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <limits.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <sys/mman.h>
#include <unistd.h>
#endif
#include <os-interface.h>
#include <nvidia-modeset-os-interface.h>
#include "log.h"

static unsigned checks, comparisons, records;
static NvU32 last_severity;
static char last_record[513];
static int reject_log;
static void check(int condition, int line)
{
    ++checks;
    if (!condition) { fprintf(stderr, "RM format check failed at line %d\n", line); exit(1); }
}
#define CHECK(condition) check(!!(condition), __LINE__)

NvS32 r4nv_log(NvU32 severity, const char *text)
{
    if (reject_log || text == NULL || severity > R4NV_LOG_ERROR) return -1;
    size_t size = strlen(text);
    CHECK(size <= 512);
    memcpy(last_record, text, size + 1);
    last_severity = severity; ++records;
    return (NvS32)size;
}

static void compare(size_t capacity, const char *format, ...)
{
    unsigned char reference[256], rm[256], kms[256];
    CHECK(capacity <= 192);
    memset(reference, 0xa5, sizeof(reference));
    memset(rm, 0xa5, sizeof(rm));
    memset(kms, 0xa5, sizeof(kms));
    va_list args, copy;
    va_start(args, format);
    va_copy(copy, args);
    int expected = vsnprintf((char *)reference + 16, capacity, format, copy);
    va_end(copy);
    va_copy(copy, args);
    int actual_rm = os_vsnprintf((char *)rm + 16, (NvU32)capacity, format, copy);
    va_end(copy);
    va_copy(copy, args);
    int actual_kms = nvkms_vsnprintf((char *)kms + 16, capacity, format, copy);
    va_end(copy);
    va_end(args);
    if (expected != actual_rm || expected != actual_kms ||
        memcmp(reference, rm, sizeof(rm)) || memcmp(reference, kms, sizeof(kms))) {
        fprintf(stderr, "format=%s capacity=%zu expected=%d rm=%d kms=%d\n", format, capacity, expected, actual_rm, actual_kms);
        CHECK(0);
    }
    ++comparisons;
}
static void invalid(const char *format, ...)
{
    char a[64], b[64];
    memset(a, 0xa5, sizeof(a)); memset(b, 0xa5, sizeof(b));
    va_list args, copy;
    va_start(args, format);
    va_copy(copy, args);
    CHECK(os_vsnprintf(a + 1, 32, format, copy) == -1);
    va_end(copy);
    va_copy(copy, args);
    CHECK(nvkms_vsnprintf(b + 1, 32, format, copy) == -1);
    va_end(copy); va_end(args);
    CHECK(a[1] == 0 && b[1] == 0);
    CHECK((unsigned char)a[0] == 0xa5 && (unsigned char)b[0] == 0xa5);
    for (size_t i = 33; i < sizeof(a); ++i) CHECK((unsigned char)a[i] == 0xa5 && (unsigned char)b[i] == 0xa5);
}
static void log_error(const char *format, ...)
{
    va_list args; va_start(args, format); os_log_error(format, args); va_end(args);
}
static void guard_checks(void)
{
#if defined(_WIN32)
    SYSTEM_INFO info; GetSystemInfo(&info);
    size_t page = info.dwPageSize;
    char *memory = VirtualAlloc(NULL, page * 2, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    CHECK(memory != NULL);
    DWORD previous;
    CHECK(VirtualProtect(memory + page, page, PAGE_NOACCESS, &previous));
#else
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    char *memory = mmap(NULL, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(memory != MAP_FAILED);
    CHECK(mprotect(memory + page, page, PROT_NONE) == 0);
#endif
    char *end = memory + page;
    memcpy(end - 3, "abc", 3); /* deliberately no readable terminator */
    char output[8];
    CHECK(os_snprintf(output, sizeof(output), "%.3s", end - 3) == 3 && strcmp(output, "abc") == 0);
    CHECK(nvkms_snprintf(output, sizeof(output), "%.*s", 3, end - 3) == 3 && strcmp(output, "abc") == 0);
    CHECK(os_snprintf(output, sizeof(output), "%.0s", end) == 0 && output[0] == 0);
    CHECK(nvkms_snprintf(NULL, 0, "%.0s", end) == 0);
    for (unsigned size = 1; size <= 64; ++size) {
        CHECK(os_snprintf(end - size, size, "test:%080llx", 0xabcdef1234567890ULL) == 85);
        CHECK(end[-1] == 0);
        CHECK(nvkms_snprintf(end - size, size, "test:%080llx", 0xabcdef1234567890ULL) == 85);
        CHECK(end[-1] == 0);
    }
#if defined(_WIN32)
    CHECK(VirtualFree(memory, 0, MEM_RELEASE));
#else
    CHECK(munmap(memory, page * 2) == 0);
#endif
}

int main(void)
{
    for (size_t capacity = 0; capacity <= 192; ++capacity) {
        compare(capacity, "");
        compare(capacity, "literal %% tail");
        compare(capacity, "%+08d|% 11i|%-9d|%u|%#o|%#x|%#X", INT_MIN, -123, 19, UINT_MAX, 0777U, 0xfedcU, 0xabcdefU);
        compare(capacity, "%hhd/%hhu/%hd/%hu", -128, 255U, -32768, 65535U);
        compare(capacity, "%ld/%lu/%lld/%llu", LONG_MIN, ULONG_MAX, LLONG_MIN, ULLONG_MAX);
        compare(capacity, "%zu/%zd/%td/%tu/%jd/%ju", SIZE_MAX, (intptr_t)-123, (ptrdiff_t)-99, (uintptr_t)987, (intmax_t)INTMAX_MIN, (uintmax_t)UINTMAX_MAX);
        compare(capacity, "%.*s|%*.*d|%-12c|%c", 3, "abcdef", -12, 8, -37, 'Z', '\0');
        compare(capacity, "%.0u|%#.0o|%.0x|%#.0x|%#8.5o|%08.5d", 0U, 0U, 0U, 0U, 23U, -12);
        compare(capacity, "%*.*s/%*.*u", 12, -1, "unlimited", 8, -1, 19U);
    }
    uint64_t random = 0x7614a5bc00979ULL;
    for (unsigned i = 0; i < 4096; ++i) {
        random ^= random << 13; random ^= random >> 7; random ^= random << 17;
        int width = (int)(random % 65) - 32;
        int precision = (int)((random >> 7) % 34) - 2;
        size_t capacity = (size_t)((random >> 17) % 193);
        compare(capacity, "%+0*.*lld/%#*.*llx/%#*.*llo",
                width, precision, (long long)random,
                width, precision, (unsigned long long)random,
                width, precision, (unsigned long long)random);
    }
    char output[64];
    CHECK(os_snprintf(output, sizeof(output), "%p", (void *)(uintptr_t)0x1234) == 16);
    CHECK(strcmp(output, "0000000000001234") == 0);
    CHECK(nvkms_snprintf(output, sizeof(output), "%p", (void *)NULL) == 16 && strcmp(output, "0000000000000000") == 0);
    CHECK(os_snprintf(output, sizeof(output), "0x%p", (void *)(uintptr_t)0x1234) == 18 && strcmp(output, "0x0000000000001234") == 0);
    CHECK(os_snprintf(NULL, 0, "%2147483647s", "") == INT_MAX);
    CHECK(nvkms_snprintf(output, 8, "%2147483647s", "") == INT_MAX && strcmp(output, "       ") == 0);
    CHECK(os_snprintf(output, 8, "%.2147483647u", 1U) == INT_MAX && strcmp(output, "0000000") == 0);
    int untouched = 79;
    invalid("before%n", &untouched); CHECK(untouched == 79);
    invalid("%f", 1.0); invalid("%2$d", 1, 2); invalid("%pS", (void *)(uintptr_t)1);
    invalid("%ls", L"wide"); invalid("%"); invalid("%ll"); invalid("%2147483648d", 1);
    invalid("%*d", INT_MIN, 1); invalid("%2147483647s!", ""); invalid("%+.2147483647d", 1);
    CHECK(os_snprintf(NULL, 1, "x") == -1);
    CHECK(os_snprintf(output, sizeof(output), NULL) == -1 && output[0] == 0);
    CHECK(nvkms_snprintf(output, (size_t)-1, "x") == -1 && output[0] == 0);
    char *large = malloc(65537);
    CHECK(large != NULL); memset(large, 's', 65536); large[65536] = 0;
    invalid("%s", large); invalid(large);
    free(large);
    guard_checks();

    os_dbg_set_level(0xffffffffU);
    CHECK(nv_printf(NV_DBG_INFO, "filtered") == 0 && records == 0);
    CHECK(nv_printf(NV_DBG_WARNINGS, "warn:%llu", ULLONG_MAX) == 25);
    CHECK(last_severity == R4NV_LOG_WARN && strcmp(last_record, "warn:18446744073709551615") == 0);
    os_dbg_set_level(0);
    CHECK(nv_printf(NV_DBG_INFO, "info:%x", 0x79U) == 7 && last_severity == R4NV_LOG_INFO);
    CHECK(nv_printf(NV_DBG_ERRORS, "error:%d", -79) == 9 && last_severity == R4NV_LOG_ERROR);
    out_string("literal %n stays literal");
    CHECK(last_severity == R4NV_LOG_INFO && strcmp(last_record, "literal %n stays literal") == 0);
    log_error("explicit:%#llx", 0x123456789abcdef0ULL);
    CHECK(last_severity == R4NV_LOG_ERROR && strcmp(last_record, "explicit:0x123456789abcdef0") == 0);
    nvkms_log(NVKMS_LOG_LEVEL_WARN, "GPU-0: ", "warning");
    CHECK(last_severity == R4NV_LOG_WARN && strcmp(last_record, "NVIDIA modeset: GPU-0: warning") == 0);
    nvkms_log(NVKMS_LOG_LEVEL_ERROR, NULL, NULL);
    CHECK(last_severity == R4NV_LOG_ERROR && strcmp(last_record, "NVIDIA modeset: (null)") == 0);
    nvkms_log(99, "", "default");
    CHECK(last_severity == R4NV_LOG_INFO);
    CHECK(nv_printf(NV_DBG_ERRORS, "%01000d", 1) == 511);
    CHECK(strlen(last_record) == 511 && strcmp(last_record + 499, " [truncated]") == 0);
    CHECK(nv_printf(NV_DBG_ERRORS, "%n", &untouched) == -1 && untouched == 79);
    CHECK(last_severity == R4NV_LOG_ERROR && strcmp(last_record, "NVIDIA native log: invalid or unsupported format") == 0);
    unsigned before = records;
    reject_log = 1;
    CHECK(nv_printf(NV_DBG_ERRORS, "closed") == -1 && records == before);
    printf("RM format adapters: OK checks=%u comparisons=%u records=%u guard-pages=active gpu=none\n", checks, comparisons, records);
    return 0;
}
