/* Host-only oracle using complete pinned NVIDIA headers and original checksum.
 * No replacement RPC union/types, queue submission or GPU callback. */
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include "core/core.h"
#include "os/os.h"
#include "vgpu/rpc_headers.h"
#include "gpu/mem_mgr/virt_mem_allocator_common.h"
#define RPC_STRUCTURES
#define RPC_GENERIC_UNION
#include "g_rpc-structures.h"
#undef RPC_STRUCTURES
#undef RPC_GENERIC_UNION
#define RPC_MESSAGE_STRUCTURES
#include "g_rpc-message-header.h"
#undef RPC_MESSAGE_STRUCTURES
#include "gpu/gsp/message_queue.h"
#include "gpu/gsp/message_queue_priv.h"
#include "ctrl/ctrl2080/ctrl2080nvd.h"
#include "rmgspseq.h"
#include "gpu/gpu_timeout.h"
#include "gpu/falcon/falcon_common.h"
#include "published/ampere/ga102/dev_gsp.h"
#include "published/ampere/ga102/dev_gsp_addendum.h"
#include "published/ampere/ga102/dev_sec_pri.h"
#include "published/ampere/ga102/dev_sec_addendum.h"
#include "published/ampere/ga102/dev_falcon_second_pri.h"
#include "published/ampere/ga102/dev_falcon_v4.h"
#include "published/ampere/ga102/dev_falcon_v4_addendum.h"
#include "published/ampere/ga102/dev_fbif_v4.h"
#include "published/ampere/ga102/dev_riscv_pri.h"
#include "published/ampere/ga102/dev_gc6_island.h"
#include "published/ampere/ga102/dev_gc6_island_addendum.h"

int r4nv_falcon_hs_abi_check(const unsigned *actual, size_t count)
{
    const NvU32 expected[] = {
        DRF_BASE(NV_PGSP), DRF_BASE(NV_PSEC),
        NV_PGSP_FBIF_BASE - DRF_BASE(NV_PGSP),
        NV_PSEC_FBIF_BASE - DRF_BASE(NV_PSEC),
        NV_FALCON2_GSP_BASE - DRF_BASE(NV_PGSP),
        NV_FALCON2_SEC_BASE - DRF_BASE(NV_PSEC),
        NV_PFALCON_FBIF_CTL, NV_PFALCON_FBIF_TRANSCFG(0),
        NV_PFALCON_FALCON_DMACTL, NV_PFALCON_FALCON_DMATRFBASE,
        NV_PFALCON_FALCON_DMATRFBASE1, NV_PFALCON_FALCON_DMATRFMOFFS,
        NV_PFALCON_FALCON_DMATRFFBOFFS, NV_PFALCON_FALCON_DMATRFCMD,
        NV_PFALCON2_FALCON_BROM_PARAADDR(0), NV_PFALCON2_FALCON_BROM_ENGIDMASK,
        NV_PFALCON2_FALCON_BROM_CURR_UCODE_ID, NV_PFALCON2_FALCON_MOD_SEL,
        NV_PFALCON_FALCON_BOOTVEC, NV_PFALCON_FALCON_CPUCTL,
        NV_PFALCON_FALCON_CPUCTL_ALIAS, NV_PFALCON_FALCON_MAILBOX0,
        NV_PFALCON_FALCON_MAILBOX1,
        DRF_DEF(_PFALCON, _FBIF_CTL, _ALLOW_PHYS_NO_CTX, _ALLOW),
        DRF_SHIFTMASK(NV_PFALCON_FBIF_TRANSCFG_TARGET) |
          DRF_SHIFTMASK(NV_PFALCON_FBIF_TRANSCFG_MEM_TYPE),
        DRF_DEF(_PFALCON, _FBIF_TRANSCFG, _TARGET, _COHERENT_SYSMEM) |
          DRF_DEF(_PFALCON, _FBIF_TRANSCFG, _MEM_TYPE, _PHYSICAL),
        DRF_DEF(_PFALCON, _FALCON_DMATRFCMD, _FULL, _TRUE),
        DRF_DEF(_PFALCON, _FALCON_DMATRFCMD, _IDLE, _TRUE),
        DRF_DEF(_PFALCON, _FALCON_DMATRFCMD, _IMEM, _TRUE) |
          DRF_NUM(_PFALCON, _FALCON_DMATRFCMD, _SEC, 1) |
          DRF_DEF(_PFALCON, _FALCON_DMATRFCMD, _SIZE, _256B),
        DRF_DEF(_PFALCON, _FALCON_DMATRFCMD, _IMEM, _FALSE) |
          DRF_NUM(_PFALCON, _FALCON_DMATRFCMD, _SEC, 0) |
          DRF_DEF(_PFALCON, _FALCON_DMATRFCMD, _SIZE, _256B),
        DRF_DEF(_PFALCON2, _FALCON_MOD_SEL, _ALGO, _RSA3K),
        DRF_DEF(_PFALCON, _FALCON_CPUCTL, _ALIAS_EN, _TRUE),
        DRF_DEF(_PFALCON, _FALCON_CPUCTL, _STARTCPU, _TRUE),
        DRF_DEF(_PFALCON, _FALCON_CPUCTL, _HALTED, _TRUE)
    };
    return count != sizeof(expected) / sizeof(expected[0]) ||
           memcmp(actual, expected, sizeof(expected)) != 0;
}

int r4nv_gsp_core_abi_check(const unsigned *actual, size_t count)
{
    const NvU32 expected[] = {
        DRF_BASE(NV_PGSP) + NV_PFALCON_FALCON_HWCFG2,
        NV_PGSP_FALCON_ENGINE,
        DRF_BASE(NV_PGSP) + NV_PFALCON_FALCON_RM,
        NV_PGSP_FBIF_BASE + NV_PFALCON_FBIF_CTL,
        DRF_BASE(NV_PGSP) + NV_PFALCON_FALCON_DMACTL,
        DRF_BASE(NV_PGSP) + NV_PFALCON_FALCON_CPUCTL,
        DRF_BASE(NV_PGSP) + NV_PFALCON_FALCON_CPUCTL_ALIAS,
        NV_FALCON2_GSP_BASE + NV_PRISCV_RISCV_BCR_CTRL,
        NV_FALCON2_GSP_BASE + NV_PRISCV_RISCV_CPUCTL,
        NV_PGSP_FALCON_MAILBOX0, NV_PGSP_FALCON_MAILBOX1,
        DRF_BASE(NV_PGSP) + NV_PFALCON_FALCON_OS,
        DRF_BASE(NV_PSEC) + NV_PFALCON_FALCON_CPUCTL,
        DRF_BASE(NV_PSEC) + NV_PFALCON_FALCON_CPUCTL_ALIAS,
        DRF_BASE(NV_PSEC) + NV_PFALCON_FALCON_MAILBOX0,
        NV_PGC6_BSI_SECURE_SCRATCH_14,
        DRF_DEF(_PFALCON, _FALCON_HWCFG2, _RESET_READY, _TRUE),
        DRF_SHIFTMASK(NV_PFALCON_FALCON_HWCFG2_MEM_SCRUBBING),
        DRF_DEF(_PFALCON, _FALCON_HWCFG2, _RISCV, _ENABLE),
        DRF_DEF(_PGSP, _FALCON_ENGINE, _RESET, _TRUE),
        DRF_DEF(_PFALCON, _FBIF_CTL, _ALLOW_PHYS_NO_CTX, _ALLOW),
        DRF_DEF(_PFALCON, _FALCON_CPUCTL, _STARTCPU, _TRUE),
        DRF_DEF(_PFALCON, _FALCON_CPUCTL, _ALIAS_EN, _TRUE),
        DRF_DEF(_PFALCON, _FALCON_CPUCTL, _HALTED, _TRUE),
        DRF_DEF(_PRISCV_RISCV, _BCR_CTRL, _CORE_SELECT, _RISCV),
        DRF_DEF(_PRISCV_RISCV, _BCR_CTRL, _VALID, _TRUE),
        DRF_DEF(_PRISCV_RISCV, _BCR_CTRL, _CORE_SELECT, _RISCV) |
          DRF_DEF(_PRISCV_RISCV, _BCR_CTRL, _VALID, _TRUE) |
          DRF_DEF(_PRISCV_RISCV, _BCR_CTRL, _BRFETCH, _TRUE),
        DRF_DEF(_PRISCV_RISCV, _CPUCTL, _ACTIVE_STAT, _ACTIVE),
        DRF_DEF(_PGC6, _BSI_SECURE_SCRATCH_14, _BOOT_STAGE_3_HANDOFF, _VALUE_DONE),
        FLCN_RESET_PROPAGATION_DELAY_COUNT,
        DRF_BASE(NV_PSEC) + NV_PFALCON_FALCON_HWCFG2,
        NV_PSEC_FALCON_ENGINE,
        DRF_BASE(NV_PSEC) + NV_PFALCON_FALCON_RM,
        NV_PSEC_FBIF_BASE + NV_PFALCON_FBIF_CTL,
        DRF_BASE(NV_PSEC) + NV_PFALCON_FALCON_DMACTL,
        NV_FALCON2_SEC_BASE + NV_PRISCV_RISCV_BCR_CTRL,
        DRF_DEF(_PSEC, _FALCON_ENGINE, _RESET, _TRUE),
        NV_PFALCON_FALCON_HWCFG,
        DRF_MASK(NV_PFALCON_FALCON_HWCFG_IMEM_SIZE) * FLCN_BLK_ALIGNMENT
    };
    return count != sizeof(expected) / sizeof(expected[0]) ||
           memcmp(actual, expected, sizeof(expected)) != 0;
}

_Static_assert(sizeof(rpc_message_header_v) == 32, "complete original RPC header");
_Static_assert(sizeof(GSP_MSG_QUEUE_ELEMENT) == 80, "minimum message");
_Static_assert(GSP_MSG_QUEUE_ELEMENT_HDR_SIZE == 48, "outer header including alignment");
_Static_assert(offsetof(GSP_MSG_QUEUE_ELEMENT, checkSum) == 32, "checksum");
_Static_assert(offsetof(GSP_MSG_QUEUE_ELEMENT, seqNum) == 36, "queue sequence");
_Static_assert(offsetof(GSP_MSG_QUEUE_ELEMENT, elemCount) == 40, "element count");
_Static_assert(offsetof(rpc_message_header_v, rpc_message_data) == 32, "payload");
_Static_assert(GSP_MSG_QUEUE_ELEMENT_SIZE_MIN == 4096, "queue element");
_Static_assert(GSP_MSG_QUEUE_ELEMENT_SIZE_MAX == 65536, "maximum frame");
static unsigned compared;

/* Keep the original checked-build assertion enabled. Any assertion/debug
 * callback terminates this host verifier; none supplies a success result. */
void nvAssertFailedNoLog(NV_ASSERT_FAILED_FUNC_TYPE)
{
    (void)pszExpr;
    (void)pszFileName;
    (void)lineNum;
    abort();
}
NvBool nvDbgBreakpointEnabled(void) { abort(); }
void NV_API_CALL os_dbg_breakpoint(void) { abort(); }

int r4nv_gsp_message_abi_check(const unsigned char *actual, size_t actual_len, unsigned fixture)
{
    static const unsigned payload_lengths[] = {0, 1, 7, 4016, 4017, 65456};
    static _Alignas(4096) unsigned char expected[GSP_MSG_QUEUE_ELEMENT_SIZE_MAX];
    if (fixture >= sizeof(payload_lengths) / sizeof(payload_lengths[0])) return 1;
    const NvU32 payload_len = payload_lengths[fixture];
    const NvU32 message_len = sizeof(GSP_MSG_QUEUE_ELEMENT) + payload_len;
    if (message_len < sizeof(GSP_MSG_QUEUE_ELEMENT) || message_len > GSP_MSG_QUEUE_ELEMENT_SIZE_MAX) return 2;
    const NvU32 elements = GSP_MSG_QUEUE_BYTES_TO_ELEMENTS(message_len);
    if (actual_len != elements * GSP_MSG_QUEUE_ELEMENT_SIZE_MIN) return 2;
    memset(expected, 0, sizeof(expected));
    GSP_MSG_QUEUE_ELEMENT *element = (void *)expected;
    rpc_message_header_v *rpc = &element->rpc;
    element->seqNum = 0xffffffffU - fixture;
    element->elemCount = elements;
    rpc->header_version = DRF_DEF(_VGPU, _MSG_HEADER_VERSION, _MAJOR, _TOT) |
                          DRF_DEF(_VGPU, _MSG_HEADER_VERSION, _MINOR, _TOT);
    rpc->signature = NV_VGPU_MSG_SIGNATURE_VALID;
    rpc->length = sizeof(*rpc) + payload_len;
    rpc->function = 0xdeadbeefU; /* Opaque framing fixture, never dispatched. */
    rpc->rpc_result = NV_VGPU_MSG_RESULT_RPC_PENDING;
    rpc->rpc_result_private = NV_VGPU_MSG_RESULT_RPC_PENDING;
    rpc->sequence = 0x12345678;
    unsigned char *payload = (void *)rpc->rpc_message_data;
    for (unsigned i = 0; i < payload_len; ++i) payload[i] = (unsigned char)(i * 37 + 11);
    /* This is the original NVIDIA inline routine, not a local checksum copy. */
    element->checkSum = _checkSum32(expected, message_len);
    if (_checkSum32(expected, message_len) != 0) return 3;
    if (memcmp(actual, expected, actual_len)) return 4;
    compared |= 1U << fixture;
    return 0;
}

int r4nv_gsp_message_abi_complete(void)
{
    return compared == 0x3f;
}

/* Genuine generated event types, including flexible-array prefixes and the
 * complete inline NOCAT record. These assertions do not define shadow types. */
_Static_assert(sizeof(rpc_init_done_v) == 4, "init done unused word");
_Static_assert(sizeof(rpc_gsp_lockdown_notice_v) == 1, "lockdown NvBool");
_Static_assert(sizeof(rpc_run_cpu_sequencer_v) == 40, "sequencer prefix");
_Static_assert(offsetof(rpc_run_cpu_sequencer_v, commandBuffer) == 40, "sequencer words");
_Static_assert(sizeof(rpc_ucode_libos_print_v) == 8, "libos prefix");
_Static_assert(sizeof(rpc_os_error_log_v) == 272, "os error size");
_Static_assert(sizeof(NV2080CtrlNocatJournalInsertRecord) == 1208, "complete inline nocat");
_Static_assert(offsetof(NV2080CtrlNocatJournalInsertRecord, diagBufferLen) == 176, "nocat bounded length");
_Static_assert(offsetof(NV2080CtrlNocatJournalInsertRecord, diagBuffer) == 180, "nocat inline bytes");
static unsigned events_compared;

size_t r4nv_gsp_event_abi_fixture(unsigned fixture, unsigned char *output, size_t capacity)
{
    static _Alignas(4096) unsigned char frame[GSP_MSG_QUEUE_ELEMENT_SIZE_MIN];
    if (fixture >= 6 || capacity < sizeof(frame)) return 0;
    memset(frame, 0, sizeof(frame));
    GSP_MSG_QUEUE_ELEMENT *element = (void *)frame;
    rpc_message_header_v *rpc = &element->rpc;
    unsigned payload_len;
    switch (fixture) {
    case 0: {
        rpc_init_done_v *p = (void *)rpc->rpc_message_data;
        rpc->function = NV_VGPU_MSG_EVENT_GSP_INIT_DONE;
        p->not_used = 0x7ac0ffee;
        payload_len = sizeof(*p);
        break;
    }
    case 1: {
        rpc_run_cpu_sequencer_v *p = (void *)rpc->rpc_message_data;
        rpc->function = NV_VGPU_MSG_EVENT_GSP_RUN_CPU_SEQUENCER;
        p->bufferSizeDWord = 8;
        p->cmdIndex = 3;
        for (unsigned i = 0; i < 8; ++i) p->regSaveArea[i] = 0x100 + i;
        p->commandBuffer[0] = 0x11223344; /* Opaque, never executed. */
        p->commandBuffer[1] = 0x55667788;
        p->commandBuffer[2] = 0x99aabbcc;
        payload_len = sizeof(*p) + 3 * sizeof(NvU32);
        break;
    }
    case 2: {
        rpc_os_error_log_v *p = (void *)rpc->rpc_message_data;
        rpc->function = NV_VGPU_MSG_EVENT_OS_ERROR_LOG;
        p->exceptType = 119; p->runlistId = 4; p->chid = 0xffffffff;
        memset(p->errString, 'X', sizeof(p->errString)); /* No terminator. */
        p->preemptiveRemovalPreviousXid = 13;
        payload_len = sizeof(*p);
        break;
    }
    case 3: {
        rpc_ucode_libos_print_v *p = (void *)rpc->rpc_message_data;
        rpc->function = NV_VGPU_MSG_EVENT_UCODE_LIBOS_PRINT;
        p->ucodeEngDesc = 0x1234; p->libosPrintBufSize = 5;
        memcpy(p->libosPrintBuf, "\0%\xff\x1bZ", 5);
        payload_len = sizeof(*p) + 5;
        break;
    }
    case 4: {
        rpc_gsp_lockdown_notice_v *p = (void *)rpc->rpc_message_data;
        rpc->function = NV_VGPU_MSG_EVENT_GSP_LOCKDOWN_NOTICE;
        p->bLockdownEngaging = NV_TRUE;
        payload_len = sizeof(*p);
        break;
    }
    default: {
        rpc_gsp_post_nocat_record_v *rpc_p = (void *)rpc->rpc_message_data;
        NV2080CtrlNocatJournalInsertRecord *p = (void *)&rpc_p->data;
        rpc->function = NV_VGPU_MSG_EVENT_GSP_POST_NOCAT_RECORD;
        memset(p, 0xa5, sizeof(*p)); /* Padding/unused tails are not zero fields. */
        p->flags = 3; p->timestamp = 0x123456789abcdef0ULL;
        p->recType = 7; p->bugcheck = 0x79;
        memcpy(p->source, "rm", 3); p->subsystem = 8;
        p->errorCode = 0xfedcba9876543210ULL;
        memcpy(p->faultingEngine, "gsp", 4); p->tdrReason = 12;
        p->diagBufferLen = 5; memcpy(p->diagBuffer, "\xde\xad\xbe\xef\x79", 5);
        payload_len = sizeof(*p);
        break;
    }
    }
    element->seqNum = 10 + fixture;
    element->elemCount = 1;
    rpc->header_version = DRF_DEF(_VGPU, _MSG_HEADER_VERSION, _MAJOR, _TOT) |
                          DRF_DEF(_VGPU, _MSG_HEADER_VERSION, _MINOR, _TOT);
    rpc->signature = NV_VGPU_MSG_SIGNATURE_VALID;
    rpc->length = sizeof(*rpc) + payload_len;
    rpc->rpc_result = fixture == 0 ? NV_OK : NV_VGPU_MSG_RESULT_RPC_PENDING;
    rpc->rpc_result_private = 0x76543210;
    rpc->sequence = 0x700 + fixture;
    element->checkSum = _checkSum32(frame, sizeof(*element) + payload_len);
    if (_checkSum32(frame, sizeof(*element) + payload_len) != 0) return 0;
    memcpy(output, frame, sizeof(frame));
    events_compared |= 1U << fixture;
    return sizeof(frame);
}

int r4nv_gsp_event_abi_complete(void) { return events_compared == 0x3f; }

_Static_assert(sizeof(GSP_SEQ_BUF_OPCODE) == 4, "sequencer opcode word");
_Static_assert(offsetof(GSP_SEQUENCER_BUFFER_CMD, payload) == 4, "immediate operands");
_Static_assert(GSP_SEQ_BUF_REG_SAVE_SIZE == 8, "saved register slots");
_Static_assert(GPU_TIMEOUT_DEFAULT == 0, "zero poll timeout inherits owner default");
static int sequence_compared;
size_t r4nv_gsp_sequence_abi_fixture(unsigned char *output, size_t capacity)
{
    if (capacity < 88) return 0;
    size_t offset = 0;
    static const GSP_SEQ_BUF_OPCODE opcodes[] = {
        GSP_SEQ_BUF_OPCODE_REG_WRITE, GSP_SEQ_BUF_OPCODE_REG_MODIFY,
        GSP_SEQ_BUF_OPCODE_REG_POLL, GSP_SEQ_BUF_OPCODE_DELAY_US,
        GSP_SEQ_BUF_OPCODE_REG_STORE, GSP_SEQ_BUF_OPCODE_CORE_RESET,
        GSP_SEQ_BUF_OPCODE_CORE_START, GSP_SEQ_BUF_OPCODE_CORE_WAIT_FOR_HALT,
        GSP_SEQ_BUF_OPCODE_CORE_RESUME
    };
    for (unsigned i = 0; i < sizeof(opcodes) / sizeof(opcodes[0]); ++i) {
        GSP_SEQUENCER_BUFFER_CMD cmd;
        memset(&cmd, 0, sizeof(cmd));
        cmd.opCode = opcodes[i];
        switch (cmd.opCode) {
        case GSP_SEQ_BUF_OPCODE_REG_WRITE:
            cmd.payload.regWrite.addr = 0x1234; cmd.payload.regWrite.val = 0x5678; break;
        case GSP_SEQ_BUF_OPCODE_REG_MODIFY:
            cmd.payload.regModify.addr = 0x5678; cmd.payload.regModify.mask = 0xff00; cmd.payload.regModify.val = 0xf00f; break;
        case GSP_SEQ_BUF_OPCODE_REG_POLL:
            cmd.payload.regPoll.addr = 0x9010; cmd.payload.regPoll.mask = 0xfff;
            cmd.payload.regPoll.val = 0x321; cmd.payload.regPoll.timeout = 7; cmd.payload.regPoll.error = 99; break;
        case GSP_SEQ_BUF_OPCODE_DELAY_US: cmd.payload.delayUs.val = 13; break;
        case GSP_SEQ_BUF_OPCODE_REG_STORE: cmd.payload.regStore.addr = 0x1100; cmd.payload.regStore.index = 7; break;
        default: break;
        }
        const size_t bytes = sizeof(cmd.opCode) + GSP_SEQUENCER_PAYLOAD_SIZE_DWORDS(cmd.opCode) * sizeof(NvU32);
        if (bytes > sizeof(cmd) || bytes > capacity - offset) return 0;
        memcpy(output + offset, &cmd, bytes);
        offset += bytes;
    }
    sequence_compared = offset == 88;
    return offset;
}
int r4nv_gsp_sequence_abi_complete(void) { return sequence_compared; }
