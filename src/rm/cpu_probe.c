/* Actual C -> private Zig provider -> R4D service integration. No host fixture
 * allocator or clock, and no native GPU or synchronization-fault dispatch. */
#include "os-interface.h"
#include "nvidia-modeset-os-interface.h"
#include "cpu_probe.h"
/* Nine original declarations, real private log provider, caller's CPU context. */
static int probe_os_v(char *data, NvU32 bytes, const char *format, ...)
{
    va_list args; va_start(args, format);
    int result = os_vsnprintf(data, bytes, format, args);
    va_end(args); return result;
}
static int probe_kms_v(char *data, size_t bytes, const char *format, ...)
{
    va_list args; va_start(args, format);
    int result = nvkms_vsnprintf(data, bytes, format, args);
    va_end(args); return result;
}
static void probe_error(const char *format, ...)
{
    va_list args; va_start(args, format);
    os_log_error(format, args); va_end(args);
}
NvS32 r4nv_format_probe(NvU32 seed)
{
    char data[96];
    int preserved = 79;
    if (os_snprintf(data, sizeof(data), "%lld/%#llx", (-9223372036854775807LL - 1), 0xfedcba9876543210ULL) != 39 ||
        os_string_compare(data, "-9223372036854775808/0xfedcba9876543210") != 0) return -__LINE__;
    if (probe_os_v(data, 5, "%08x", 0x79U) != 8 || os_string_compare(data, "0000") != 0) return -__LINE__;
    if (nvkms_snprintf(data, sizeof(data), "%zu/%hhu/%.*s", (size_t)0x100000001ULL, 255U, 3, "abcde") != 18 ||
        nvkms_strcmp(data, "4294967297/255/abc") != 0) return -__LINE__;
    if (probe_kms_v(data, sizeof(data), "%*.*d", -8, 4, -12) != 8 || nvkms_strcmp(data, "-0012   ") != 0) return -__LINE__;
    if (os_snprintf(data, sizeof(data), "%n", &preserved) != -1 || data[0] != 0 || preserved != 79) return -__LINE__;
    os_dbg_set_level(0);
    if (nv_printf(NV_DBG_INFO, "NVIDIA native-log-check: context=%u value=%016llx", seed, 0xfedcba9876543210ULL) <= 0) return -__LINE__;
    out_string("NVIDIA native-log-check: literal=100% complete");
    probe_error("NVIDIA native-log-check: severity=error context=%u", seed);
    nvkms_log(NVKMS_LOG_LEVEL_WARN, "GPU-check: ", "native-log-check severity=warning");
    return 0;
}

#define CHECK(condition) do { if (!(condition)) { result = __LINE__; goto done; } } while (0)
NvS32 r4nv_cpu_probe(NvU32 seed)
{
    NvS32 result = 0;
    NvU8 *left = NULL, *right = NULL;
    void *empty = NULL, *huge = NULL;
    char first[24], second[24];
    NvU64 before, middle, after, resolution, usec;
    CHECK(os_alloc_mem(NULL, 1) == NV_ERR_INVALID_ARGUMENT);
    CHECK(os_alloc_mem(&huge, NV_U64_MAX) == NV_ERR_NO_MEMORY && huge == NULL);
    CHECK(nvkms_alloc((size_t)-1, NV_FALSE) == NULL);
    CHECK(os_alloc_mem(&empty, 0) == NV_OK && empty != NULL);
    os_free_mem(empty);
    empty = NULL;
    empty = nvkms_alloc(0, NV_TRUE);
    CHECK(empty != NULL);
    nvkms_free(empty, 0);
    empty = NULL;
    CHECK(os_alloc_mem((void **)&left, 513) == NV_OK && left != NULL);
    right = nvkms_alloc(513, NV_TRUE);
    CHECK(right != NULL && ((NvUPtr)left & 15) == 0 && ((NvUPtr)right & 15) == 0);
    for (size_t i = 0; i != 513; ++i) CHECK(right[i] == 0);
    CHECK(os_mem_set(left, 0xa5, 513) == left);
    CHECK(nvkms_memset(right, 0x5a, 513) == right);
    for (size_t i = 1; i != 512; ++i) left[i] = (NvU8)(i * (seed | 1U) + 17U);
    CHECK(os_mem_copy(right + 1, left + 1, 511) == right + 1);
    CHECK(os_mem_cmp(left + 1, right + 1, 511) == 0);
    CHECK(left[0] == 0xa5 && left[512] == 0xa5 && right[0] == 0x5a && right[512] == 0x5a);
    CHECK(nvkms_memcpy(right, left, 513) == right && nvkms_memcmp(right, left, 513) == 0);
    CHECK(nvkms_memmove(right + 4, right + 1, 508) == right + 4);
    CHECK(nvkms_memcmp(right + 4, left + 1, 508) == 0);
    CHECK(nvkms_memmove(right + 1, right + 4, 508) == right + 1);
    CHECK(nvkms_memcmp(right + 1, left + 1, 508) == 0 && right[0] == 0xa5 && right[512] == 0xa5);
    CHECK(os_string_copy(first, "R4OS native RM") == first);
    CHECK(os_string_length(first) == 14 && os_string_compare(first, "R4OS native RM") == 0);
    CHECK(os_string_compare("RM", "RN") < 0 && os_string_compare("RN", "RM") > 0);
    CHECK(nvkms_strncpy(second, first, sizeof(second)) == second);
    CHECK(nvkms_strlen(second) == 14 && nvkms_strcmp(first, second) == 0);
    for (size_t i = 14; i != sizeof(second); ++i) CHECK(second[i] == '\0');
    CHECK(nvkms_strcmp("RM", "RN") < 0 && nvkms_strcmp("RN", "RM") > 0);
    before = os_get_current_tick();
    middle = os_get_current_tick_hr();
    resolution = os_get_tick_resolution();
    usec = nvkms_get_usec();
    after = os_get_current_tick();
    CHECK(before != NV_U64_MAX && middle >= before && after >= middle && after != NV_U64_MAX);
    CHECK(resolution != 0 && resolution != NV_U64_MAX && usec != NV_U64_MAX);
    CHECK(usec >= middle / 1000 && usec <= after / 1000);
done:
    os_free_mem(huge);
    os_free_mem(empty);
    os_free_mem(left);
    nvkms_free(right, 513);
    return result;
}
