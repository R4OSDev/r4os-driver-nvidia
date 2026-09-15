/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#include "r4os_dsc.h"
#include "nvt_dsc_pps.h"
#include <stddef.h>

_Static_assert(sizeof(R4OS_DSC_INPUT) == 120, "DSC input layout");
_Static_assert(offsetof(R4OS_DSC_INPUT, source_line_bits) == 104, "DSC input tail");
_Static_assert(sizeof(R4OS_DSC_OUTPUT) == 132, "DSC output layout");

NvS32 r4os_dsc_generate(const R4OS_DSC_INPUT *in, R4OS_DSC_OUTPUT *out)
{
    DSC_INFO caps = {0};
    MODESET_INFO mode = {0};
    WAR_DATA war = {0};
    /* The upstream opaque byte array is cast to structs containing u32s.
     * Keep its caller-owned storage aligned and bounded. */
    union { NvU64 align; DSC_GENERATE_PPS_OPAQUE_WORKAREA bytes; } scratch = {0};
    NvU32 count;
    if (!in || !out || in->transport > 2) return NVT_STATUS_INVALID_PARAMETER;
    caps.sinkCaps.decoderColorFormatMask = in->sink_formats;
    caps.sinkCaps.bitsPerPixelPrecision = in->sink_step_x16;
    caps.sinkCaps.maxSliceWidth = in->max_slice_width;
    caps.sinkCaps.sliceCountSupportedMask = in->slice_mask;
    /* Convert the documented DPCD slice mask to its largest advertised count. */
    for (count = 1; count <= 24; ++count) {
        NvU32 mask = count == 1 ? 1 : count == 2 ? 2 : count == 4 ? 8 :
            count == 6 ? 16 : count == 8 ? 32 : count == 10 ? 64 : count == 12 ? 128 :
            count == 16 ? 256 : count == 20 ? 512 : count == 24 ? 1024 : 0;
        if (in->slice_mask & mask) caps.sinkCaps.maxNumHztSlices = count;
    }
    caps.sinkCaps.lineBufferBitDepth = in->sink_line_bits;
    caps.sinkCaps.decoderColorDepthCaps = caps.sinkCaps.decoderColorDepthMask = in->bpc_mask;
    caps.sinkCaps.algorithmRevision.versionMajor = 1;
    caps.sinkCaps.algorithmRevision.versionMinor = in->revision_minor;
    caps.sinkCaps.bBlockPrediction = in->block_prediction != 0;
    caps.sinkCaps.peakThroughputMode0 = in->throughput_code;
    caps.sinkCaps.maxBitsPerPixelX16 = in->max_bpp_x16;
    caps.gpuCaps.encoderColorFormatMask = in->source_formats;
    caps.gpuCaps.lineBufferSize = in->source_line_units;
    caps.gpuCaps.bitsPerPixelPrecision = in->source_step_x16;
    caps.gpuCaps.maxNumHztSlices = in->source_slices;
    caps.gpuCaps.lineBufferBitDepth = in->source_line_bits;
    mode.pixelClockHz = in->pixel_clock_hz;
    mode.activeWidth = in->width; mode.activeHeight = in->height;
    mode.bitsPerComponent = in->bpc; mode.colorFormat = NVT_COLOR_FORMAT_RGB;
    war.connectorType = in->transport == 2 ? DSC_HDMI : DSC_DP;
    war.dpData.dpMode = in->transport == 1 ? DSC_DP_MST : DSC_DP_SST;
    /* Despite its name, upstream linkRateHz takes DP2_LINK_RATE's 10 MHz
     * units (810 for HBR3), as IS_VALID_DP2_X_LINKBW requires. */
    war.dpData.linkRateHz = in->link_rate_10mhz;
    war.dpData.laneCount = in->lanes; war.dpData.hBlank = in->hblank;
    if (in->transport == 2) {
        caps.forcedDscParams.sliceWidth = in->forced_slice_width;
        caps.forcedDscParams.dscRevision.versionMajor = 1;
        caps.forcedDscParams.dscRevision.versionMinor = 2;
        out->bpp_x16 = in->forced_bpp_x16;
    }
    return DSC_GeneratePPS(&caps, &mode, &war, in->payload_bps, &scratch.bytes, out->pps, &out->bpp_x16);
}
