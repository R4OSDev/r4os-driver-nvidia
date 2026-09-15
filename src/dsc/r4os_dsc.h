/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#ifndef R4OS_DSC_H
#define R4OS_DSC_H
#include "nvtypes.h"

/* Private C companion boundary; all units are explicit. No pointers to RM,
 * hardware, heap allocations or persistent state cross this interface. */
typedef struct {
    NvU64 pixel_clock_hz, payload_bps, link_rate_10mhz;
    NvU32 width, height, bpc, lanes, hblank, transport;
    NvU32 sink_formats, sink_step_x16, max_slice_width, slice_mask;
    NvU32 sink_line_bits, bpc_mask, revision_minor, block_prediction;
    NvU32 throughput_code, max_bpp_x16;
    NvU32 source_formats, source_line_units, source_step_x16, source_slices, source_line_bits;
    NvU32 forced_bpp_x16, forced_slice_width;
} R4OS_DSC_INPUT;
typedef struct { NvU32 pps[32]; NvU32 bpp_x16; } R4OS_DSC_OUTPUT;

NvS32 r4os_dsc_generate(const R4OS_DSC_INPUT *, R4OS_DSC_OUTPUT *);
#endif
