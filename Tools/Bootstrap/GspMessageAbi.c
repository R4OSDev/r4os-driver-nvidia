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
