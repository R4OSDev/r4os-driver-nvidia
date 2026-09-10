/* Host-only comparison with original and mechanically extracted pinned types. */
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include "FwsecAbi-original.h"
#include "gsp_fw_wpr_meta.h"

_Static_assert(sizeof(FALCON_APPLICATION_INTERFACE_HEADER_V1) == 4, "interface header");
_Static_assert(sizeof(FALCON_APPLICATION_INTERFACE_ENTRY_V1) == 8, "interface entry");
_Static_assert(sizeof(FALCON_APPLICATION_INTERFACE_DMEM_MAPPER_V3) == 64, "mapper");
_Static_assert(offsetof(FALCON_APPLICATION_INTERFACE_DMEM_MAPPER_V3, init_cmd) == 44, "command offset");
_Static_assert(sizeof(FWSECLIC_READ_VBIOS_DESC) == 24, "read VBIOS descriptor");
_Static_assert(sizeof(FWSECLIC_FRTS_REGION_DESC) == 20, "region descriptor");
_Static_assert(offsetof(FWSECLIC_FRTS_CMD, frtsRegionDesc) == 24, "region offset");
_Static_assert(sizeof(FWSECLIC_FRTS_CMD) == 48, "FRTS including tail padding");
_Static_assert(sizeof(GspFwWprMeta) == 256, "complete WPR metadata");
_Static_assert(offsetof(GspFwWprMeta, sysmemAddrOfSignature) == 72, "first-boot union");
_Static_assert(offsetof(GspFwWprMeta, bootCount) == 200, "boot count");
_Static_assert(offsetof(GspFwWprMeta, sysmemAddrOfCrashReportQueue) == 224, "crash queue union");
_Static_assert(offsetof(GspFwWprMeta, sizeOfCrashReportQueue) == 232, "crash queue size");
_Static_assert(offsetof(GspFwWprMeta, flags) == 241, "flags");
_Static_assert(offsetof(GspFwWprMeta, pmuReservedSize) == 244, "PMU reservation");
_Static_assert(offsetof(GspFwWprMeta, verified) == 248, "Booter-only verified marker");

int r4nv_fwsec_abi_check(const unsigned char *sb, size_t sb_len, unsigned sb_id,
                        const unsigned char *frts, size_t frts_len, unsigned frts_id,
                        const unsigned char *wpr, size_t wpr_len)
{
    FWSECLIC_READ_VBIOS_DESC read;
    FWSECLIC_FRTS_CMD command;
    memset(&read, 0, sizeof(read));
    memset(&command, 0, sizeof(command));
    read.version = 1;
    read.size = sizeof(read);
    read.flags = FWSECLIC_READ_VBIOS_STRUCT_FLAGS;
    command.readVbiosDesc = read;
    command.frtsRegionDesc.version = 1;
    command.frtsRegionDesc.size = sizeof(command.frtsRegionDesc);
    command.frtsRegionDesc.frtsRegionOffset4K = (NvU32)(0x123456000ULL >> 12);
    command.frtsRegionDesc.frtsRegionSize = FWSECLIC_FRTS_REGION_SIZE_1MB_IN_4K;
    command.frtsRegionDesc.frtsRegionMediaType = FWSECLIC_FRTS_REGION_MEDIA_FB;
    if (sb_len != sizeof(read) || frts_len != sizeof(command) ||
        sb_id != FALCON_APPLICATION_INTERFACE_DMEM_MAPPER_V3_CMD_SB ||
        frts_id != FALCON_APPLICATION_INTERFACE_DMEM_MAPPER_V3_CMD_FRTS) return 1;
    if (memcmp(sb, &read, sizeof(read)) || memcmp(frts, &command, sizeof(command))) return 2;
    /* Independent original-C structure initialization for the recorded 12-GB
     * GA106 layout. DMA values are synthetic, not claimed hardware ownership. */
    GspFwWprMeta meta;
    memset(&meta, 0, sizeof(meta));
    meta.magic = GSP_FW_WPR_META_MAGIC;
    meta.revision = GSP_FW_WPR_META_REVISION;
    meta.sysmemAddrOfRadix3Elf = 0x200000000ULL;
    meta.sizeOfRadix3Elf = 63541248;
    meta.sysmemAddrOfBootloader = 0x300000000ULL;
    meta.sizeOfBootloader = 24576;
    meta.bootloaderCodeOffset = 6144;
    meta.bootloaderDataOffset = 2048;
    meta.sysmemAddrOfSignature = 0x300006000ULL;
    meta.sizeOfSignature = 4096;
    meta.gspFwRsvdStart = meta.nonWprHeapOffset = 0x2f4000000ULL;
    meta.nonWprHeapSize = 0x100000;
    meta.gspFwWprStart = 0x2f4100000ULL;
    meta.gspFwHeapOffset = 0x2f4200000ULL;
    meta.gspFwHeapSize = 0x8000000;
    meta.gspFwOffset = 0x2fc240000ULL;
    meta.bootBinOffset = 0x2ffeda000ULL;
    meta.frtsOffset = 0x2ffee0000ULL;
    meta.frtsSize = 0x100000;
    meta.gspFwWprEnd = meta.vgaWorkspaceOffset = 0x2fffe0000ULL;
    meta.fbSize = 0x300000000ULL;
    meta.vgaWorkspaceSize = 0x20000;
    meta.sysmemAddrOfCrashReportQueue = 0x300007000ULL;
    meta.sizeOfCrashReportQueue = 16384;
    if (wpr_len != sizeof(meta) || memcmp(wpr, &meta, sizeof(meta))) return 3;
    puts("{\"schema\":1,\"original_typedefs\":true,\"zig_c_byte_comparison\":true,"
         "\"interface_header_bytes\":4,\"interface_entry_bytes\":8,\"mapper_bytes\":64,"
         "\"init_command_offset\":44,\"sb_bytes\":24,\"frts_region_bytes\":20,"
         "\"frts_region_offset\":24,\"frts_bytes\":48,\"frts_padding_zero\":true,"
         "\"gsp_wpr_bytes\":256,\"gsp_wpr_byte_comparison\":true,"
         "\"gsp_wpr_crash_queue_offset\":224,\"gsp_wpr_verified_offset\":248,"
         "\"gsp_wpr_flags_zero\":true,\"synthetic_dma_bindings\":true,"
         "\"gpu_executed\":false}");
    return 0;
}
