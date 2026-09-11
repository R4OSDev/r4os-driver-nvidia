/* Host-only comparison with original and mechanically extracted pinned types. */
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include "FwsecAbi-original.h"
#include "gsp_fw_wpr_meta.h"
#include "libos_init_args.h"
#include "gsp_init_args.h"
#include "msgq/msgq_priv.h"

_Static_assert(sizeof(LibosMemoryRegionInitArgument) == 32, "Libos entry including zero padding");
_Static_assert(offsetof(LibosMemoryRegionInitArgument, kind) == 24, "Libos kind");
_Static_assert(offsetof(LibosMemoryRegionInitArgument, loc) == 25, "Libos location");
_Static_assert(sizeof(MESSAGE_QUEUE_INIT_ARGUMENTS) == 32, "native 64-bit queue arguments");
_Static_assert(offsetof(MESSAGE_QUEUE_INIT_ARGUMENTS, cmdQueueOffset) == 16, "queue offset alignment");
_Static_assert(sizeof(GSP_ARGUMENTS_CACHED) == 72, "complete RM arguments");
_Static_assert(offsetof(GSP_ARGUMENTS_CACHED, srInitArguments) == 32, "PM arguments");
_Static_assert(offsetof(GSP_ARGUMENTS_CACHED, gpuInstance) == 44, "GPU instance");
_Static_assert(offsetof(GSP_ARGUMENTS_CACHED, bDmemStack) == 48, "default DMEM stack");
_Static_assert(offsetof(GSP_ARGUMENTS_CACHED, profilerArgs) == 56, "profiler padding");
_Static_assert(sizeof(msgqTxHeader) == 32 && sizeof(msgqRxHeader) == 4, "original queue headers");
_Static_assert(offsetof(msgqTxHeader, rxHdrOff) == 24 && offsetof(msgqTxHeader, entryOff) == 28, "queue offsets");
static int init_compared;
static unsigned rings_compared;
extern int r4nv_gsp_message_abi_complete(void);
extern int r4nv_gsp_event_abi_complete(void);
extern int r4nv_gsp_sequence_abi_complete(void);

static NvU64 init_id(const char *name)
{
    NvU64 id = 0;
    for (unsigned i = 0; i < 8 && name[i]; ++i) id = (id << 8) | (unsigned char)name[i];
    return id;
}

/* Original C types and actual upstream msgqInit/msgqTxCreate supply an
 * independent host reference. No target callback or GPU is involved. */
int r4nv_gsp_init_abi_check(const unsigned char *actual, size_t actual_len)
{
    enum { page = 4096, log_size = 65536, queue_size = 262144,
           queue_start = 2 * page + 5 * log_size, total = queue_start + page + 2 * queue_size };
    static _Alignas(4096) unsigned char expected[total];
    static const char *names[] = {"LOGINIT", "LOGINTR", "LOGRM", "LOGMNOC", "LOGKRNL"};
    init_compared = 0;
    if (actual_len != sizeof(expected)) return 1;
    memset(expected, 0, sizeof(expected));
    LibosMemoryRegionInitArgument *regions = (void *)expected;
    for (unsigned i = 0; i < 6; ++i)
    {
        regions[i].kind = LIBOS_MEMORY_REGION_CONTIGUOUS;
        regions[i].loc = LIBOS_MEMORY_REGION_LOC_SYSMEM;
        regions[i].id8 = init_id(i < 5 ? names[i] : "RMARGS");
        regions[i].pa = i < 5 ? 0x910000000ULL + i * 0x20000 : 0x900001000ULL;
        regions[i].size = i < 5 ? log_size : page;
        if (i < 5)
        {
            NvU64 *log = (void *)(expected + 2 * page + i * log_size);
            for (unsigned p = 0; p < 16; ++p) log[p + 1] = regions[i].pa + p * page;
        }
    }
    GSP_ARGUMENTS_CACHED *rm = (void *)(expected + page);
    rm->messageQueueInitArguments.sharedMemPhysAddr = 0xa00000000ULL;
    rm->messageQueueInitArguments.pageTableEntryCount = 129;
    rm->messageQueueInitArguments.cmdQueueOffset = page;
    rm->messageQueueInitArguments.statQueueOffset = page + queue_size;
    rm->bDmemStack = NV_TRUE;
    NvU64 *table = (void *)(expected + queue_start);
    table[0] = 0xa00000000ULL;
    for (unsigned i = 1; i < 129; ++i)
        table[i] = i < 17 ? 0xb00000000ULL + (i - 1) * page : 0xc00000000ULL + (i - 17) * page;
    msgqMetadata tracking;
    msgqHandle handle;
    if (msgqInit(&handle, &tracking) != 0 ||
        msgqTxCreate(handle, expected + queue_start + page, queue_size, page, 4, 12, MSGQ_FLAGS_SWAP_RX) != 0) return 2;
    if (tracking.tx.msgCount != 63 || tracking.txFree != 62 || tracking.rxLinked || tracking.rxSwapped) return 3;
    if (memcmp(actual, expected, sizeof(expected))) return 4;
    init_compared = 1;
    return 0;
}

/* Both endpoints are original host msgq instances with different RX offsets.
 * Compare negotiated routing and actual original cursor/slot operations. */
int r4nv_gsp_ring_abi_check(const NvU32 *actual, size_t actual_len, unsigned fixture)
{
    static _Alignas(4096) unsigned char command[262144], status[262144];
    msgqMetadata cpu, peer;
    msgqHandle cpu_handle, peer_handle;
    NvU32 expected[48] = {0};
    if (fixture >= 8 || actual_len != sizeof(expected)) return 1;
    memset(command, 0, sizeof(command));
    memset(status, 0, sizeof(status));
    if (msgqInit(&cpu_handle, &cpu) || msgqInit(&peer_handle, &peer) ||
        msgqTxCreate(cpu_handle, command, sizeof(command), 4096, 4, 12, (fixture & 1) ? MSGQ_FLAGS_SWAP_RX : 0) ||
        msgqTxCreate(peer_handle, status, sizeof(status), 4096, 6, 12, (fixture & 2) ? MSGQ_FLAGS_SWAP_RX : 0) ||
        msgqRxLink(cpu_handle, status, sizeof(status), 4096) ||
        msgqRxLink(peer_handle, command, sizeof(command), 4096)) return 2;
    const unsigned count = fixture < 4 ? 1 : 16;
    cpu.tx.writePtr = *cpu.pWriteOutgoing = 60;
    cpu.rxReadPtr = *cpu.pReadOutgoing = 60;
    *(NvU32 *)cpu.pReadIncoming = 40;
    *(NvU32 *)cpu.pWriteIncoming = 14;
    expected[0] = cpu.rxSwapped;
    const NvUPtr incoming = (NvUPtr)cpu.pReadIncoming;
    const NvUPtr outgoing = (NvUPtr)cpu.pReadOutgoing;
    expected[1] = incoming >= (NvUPtr)status && incoming < (NvUPtr)status + sizeof(status);
    expected[2] = incoming - (expected[1] ? (NvUPtr)status : (NvUPtr)command);
    expected[3] = outgoing >= (NvUPtr)status && outgoing < (NvUPtr)status + sizeof(status);
    expected[4] = outgoing - (expected[3] ? (NvUPtr)status : (NvUPtr)command);
    expected[5] = cpu.tx.rxHdrOff;
    expected[6] = cpu.rx.rxHdrOff;
    expected[7] = cpu.tx.msgCount;
    expected[8] = cpu.rx.msgCount;
    expected[9] = msgqTxGetFreeSpace(cpu_handle);
    expected[10] = msgqRxGetReadAvailable(cpu_handle);
    expected[15] = count;
    for (unsigned i = 0; i < count; ++i)
    {
        const void *tx = msgqTxGetWriteBuffer(cpu_handle, i);
        const void *rx = msgqRxGetReadBuffer(cpu_handle, i);
        if (!tx || !rx) return 3;
        expected[16 + i] = (const unsigned char *)tx - command;
        expected[32 + i] = (const unsigned char *)rx - status;
    }
    if (msgqTxSubmitBuffers(cpu_handle, count) || msgqRxMarkConsumed(cpu_handle, count)) return 4;
    expected[11] = cpu.tx.writePtr;
    expected[12] = cpu.rxReadPtr;
    expected[13] = *cpu.pWriteOutgoing;
    expected[14] = *cpu.pReadOutgoing;
    if (memcmp(actual, expected, sizeof(expected))) return 5;
    rings_compared |= 1U << fixture;
    return 0;
}

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
    if (!init_compared || rings_compared != 0xff || !r4nv_gsp_message_abi_complete() || !r4nv_gsp_event_abi_complete() || !r4nv_gsp_sequence_abi_complete()) return 4;
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
         "\"gsp_init_byte_comparison\":true,\"gsp_init_bytes\":864256,"
         "\"libos_entry_bytes\":32,\"rm_arguments_bytes\":72,"
         "\"queue_pages_self_mapped\":129,\"queue_ring_slots\":63,\"queue_capacity\":62,"
         "\"original_msgq_create_executed_on_host\":true,\"status_queue_zero\":true,"
         "\"gsp_message_byte_comparison\":true,\"gsp_message_fixtures\":6,"
         "\"gsp_boot_event_original_comparison\":true,\"gsp_boot_event_fixtures\":6,"
         "\"gsp_sequencer_original_comparison\":true,\"gsp_sequencer_opcodes\":9,"
         "\"gsp_core_register_original_comparison\":true,\"gsp_core_register_values\":39,"
         "\"falcon_hs_register_original_comparison\":true,\"falcon_hs_register_values\":34,"
         "\"gsp_message_outer_bytes\":48,\"gsp_rpc_header_bytes\":32,"
         "\"gsp_message_min_bytes\":80,\"gsp_message_max_bytes\":65536,"
         "\"original_gsp_checksum_executed_on_host\":true,"
         "\"gsp_ring_original_comparison\":true,\"gsp_ring_fixtures\":8,"
         "\"original_msgq_link_submit_consume_executed_on_host\":true,"
         "\"gpu_executed\":false}");
    return 0;
}
