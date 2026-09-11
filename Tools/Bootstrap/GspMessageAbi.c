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
