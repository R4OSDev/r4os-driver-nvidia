/* Original R4OS host evidence exporter. This compiles the pinned unmodified
 * NVIDIA data initializers and their decoder, never invokes firmware code. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "nvtypes.h"
#include "nvstatus.h"
#include "rmflcnbl.h"
#include "lib/zlib/inflate.h"
#define BINDATA_CONST const
#define BINDATA_INCLUDE_DATA
#include "g_bindata_kgspGetBinArchiveGspRmBoot_GA102.c"
#include "g_bindata_kgspGetBinArchiveBooterLoadUcode_GA102.c"
#include "g_bindata_kgspGetBinArchiveBooterUnloadUcode_GA102.c"
#include "g_bindata_ksec2GetBinArchiveBlUcode_TU102.c"
#undef BINDATA_INCLUDE_DATA
/* Private host records receive the original initializers. Their layout is
 * not an RM ABI and no pointer or host padding is written to the report. */
struct ExportStorage { NvU32 bytes, encoded; const void *data; NvBool compressed, override, referenced; };
#define BINDATA_INCLUDE_STORAGE_PVT_DEFN
static const struct ExportStorage entries[] = {
#include "g_bindata_kgspGetBinArchiveGspRmBoot_GA102.c"
#include "g_bindata_kgspGetBinArchiveBooterLoadUcode_GA102.c"
#include "g_bindata_kgspGetBinArchiveBooterUnloadUcode_GA102.c"
#include "g_bindata_ksec2GetBinArchiveBlUcode_TU102.c"
};
#undef BINDATA_INCLUDE_STORAGE_PVT_DEFN
static const char *names[] = {
    "GspRmBoot-GA102-ucode_image_dbg", "GspRmBoot-GA102-ucode_desc_dbg",
    "GspRmBoot-GA102-ucode_image_prod", "GspRmBoot-GA102-ucode_desc_prod",
    "BooterLoad-GA102-image_dbg", "BooterLoad-GA102-header_dbg",
    "BooterLoad-GA102-image_prod", "BooterLoad-GA102-header_prod",
    "BooterLoad-GA102-sig_dbg", "BooterLoad-GA102-sig_prod",
    "BooterLoad-GA102-patch_loc", "BooterLoad-GA102-patch_sig",
    "BooterLoad-GA102-patch_meta", "BooterLoad-GA102-num_sigs",
    "BooterUnload-GA102-image_dbg", "BooterUnload-GA102-header_dbg",
    "BooterUnload-GA102-image_prod", "BooterUnload-GA102-header_prod",
    "BooterUnload-GA102-sig_dbg", "BooterUnload-GA102-sig_prod",
    "BooterUnload-GA102-patch_loc", "BooterUnload-GA102-patch_sig",
    "BooterUnload-GA102-patch_meta", "BooterUnload-GA102-num_sigs",
    "Sec2Bl-TU102-ucode_image", "Sec2Bl-TU102-ucode_desc"
};
_Static_assert(sizeof(entries)/sizeof(entries[0]) == sizeof(names)/sizeof(names[0]), "initializer names/count");
_Static_assert(sizeof(RM_FLCN_BL_DESC) == 24, "original SEC2 descriptor");
static int save(const char *root, const char *name, const char *suffix, const void *data, size_t bytes) {
    char path[4096];
    int length = snprintf(path, sizeof(path), "%s/%s.%s", root, name, suffix);
    if (length < 0 || (size_t)length >= sizeof(path)) return 1;
    FILE *file = fopen(path, "wb");
    if (!file) return 1;
    int bad = fwrite(data, 1, bytes, file) != bytes;
    if (fclose(file)) bad = 1;
    return bad;
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    puts("[");
    for (size_t i = 0; i < sizeof(entries)/sizeof(entries[0]); ++i) {
        const struct ExportStorage *entry = &entries[i];
        if (!entry->bytes || entry->bytes > 1024*1024 || !entry->encoded || entry->encoded > 1024*1024) return 3;
        if (save(argv[1], names[i], "encoded", entry->data, entry->encoded)) return 4;
        unsigned char *guarded = malloc((size_t)entry->bytes + 128);
        if (!guarded) return 5;
        memset(guarded, 0xa5, (size_t)entry->bytes + 128);
        unsigned char *decoded = guarded + 64;
        if (entry->compressed) {
            PGZ_INFLATE_STATE decoder = NULL;
            if (utilGzAllocate(entry->data, entry->bytes, &decoder) != NV_OK || !decoder) return 6;
            NvU32 count = utilGzGetData(decoder, 0, entry->bytes, decoded);
            if (utilGzDestroy(decoder) != NV_OK || count != entry->bytes) return 7;
        } else {
            if (entry->encoded != entry->bytes) return 8;
            memcpy(decoded, entry->data, entry->bytes);
        }
        for (size_t guard = 0; guard < 64; ++guard)
            if (guarded[guard] != 0xa5 || decoded[entry->bytes + guard] != 0xa5) return 9;
        if (save(argv[1], names[i], "bin", decoded, entry->bytes)) return 10;
        free(guarded);
        printf("  {\"name\":\"%s\",\"bytes\":%u,\"encoded_bytes\":%u,\"compressed\":%s}%s\n",
               names[i], entry->bytes, entry->encoded, entry->compressed ? "true" : "false",
               i + 1 == sizeof(entries)/sizeof(entries[0]) ? "" : ",");
    }
    puts("]");
    return 0;
}
