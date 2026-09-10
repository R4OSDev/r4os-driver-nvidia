/* Host-only comparison with mechanically extracted, pinned NVIDIA typedefs. */
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include "FwsecAbi-original.h"

_Static_assert(sizeof(FALCON_APPLICATION_INTERFACE_HEADER_V1) == 4, "interface header");
_Static_assert(sizeof(FALCON_APPLICATION_INTERFACE_ENTRY_V1) == 8, "interface entry");
_Static_assert(sizeof(FALCON_APPLICATION_INTERFACE_DMEM_MAPPER_V3) == 64, "mapper");
_Static_assert(offsetof(FALCON_APPLICATION_INTERFACE_DMEM_MAPPER_V3, init_cmd) == 44, "command offset");
_Static_assert(sizeof(FWSECLIC_READ_VBIOS_DESC) == 24, "read VBIOS descriptor");
_Static_assert(sizeof(FWSECLIC_FRTS_REGION_DESC) == 20, "region descriptor");
_Static_assert(offsetof(FWSECLIC_FRTS_CMD, frtsRegionDesc) == 24, "region offset");
_Static_assert(sizeof(FWSECLIC_FRTS_CMD) == 48, "FRTS including tail padding");

int r4nv_fwsec_abi_check(const unsigned char *sb, size_t sb_len, unsigned sb_id,
                        const unsigned char *frts, size_t frts_len, unsigned frts_id)
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
    puts("{\"schema\":1,\"original_typedefs\":true,\"zig_c_byte_comparison\":true,"
         "\"interface_header_bytes\":4,\"interface_entry_bytes\":8,\"mapper_bytes\":64,"
         "\"init_command_offset\":44,\"sb_bytes\":24,\"frts_region_bytes\":20,"
         "\"frts_region_offset\":24,\"frts_bytes\":48,\"frts_padding_zero\":true,"
         "\"gpu_executed\":false}");
    return 0;
}
