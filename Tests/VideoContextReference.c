/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0
 * Host-only fixture generator. Includes the unmodified NVIDIA 570.144
 * ctrl2080gpu.h and cl2080_notification.h from the pinned source snapshot.
 * It does not substitute vendor structures or infer offsets from Zig. */
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "ctrl/ctrl2080/ctrl2080gpu.h"
#include "class/cl2080_notification.h"

int main(int argc, char **argv)
{
    if (argc != 2) return 1;
    const uint32_t layout[] = {
        NV2080_CTRL_CMD_GPU_GET_CONSTRUCTED_FALCON_INFO,
        sizeof(NV2080_CTRL_GPU_GET_CONSTRUCTED_FALCON_INFO_PARAMS),
        offsetof(NV2080_CTRL_GPU_GET_CONSTRUCTED_FALCON_INFO_PARAMS, constructedFalconsTable),
        sizeof(NV2080_CTRL_GPU_CONSTRUCTED_FALCON_INFO),
        offsetof(NV2080_CTRL_GPU_CONSTRUCTED_FALCON_INFO, ctxBufferSize),
        NV2080_CTRL_CMD_GPU_PROMOTE_CTX,
        sizeof(NV2080_CTRL_GPU_PROMOTE_CTX_PARAMS),
        offsetof(NV2080_CTRL_GPU_PROMOTE_CTX_PARAMS, hClient),
        offsetof(NV2080_CTRL_GPU_PROMOTE_CTX_PARAMS, ChID),
        offsetof(NV2080_CTRL_GPU_PROMOTE_CTX_PARAMS, hChanClient),
        offsetof(NV2080_CTRL_GPU_PROMOTE_CTX_PARAMS, hObject),
        offsetof(NV2080_CTRL_GPU_PROMOTE_CTX_PARAMS, virtAddress),
        offsetof(NV2080_CTRL_GPU_PROMOTE_CTX_PARAMS, size),
        offsetof(NV2080_CTRL_GPU_PROMOTE_CTX_PARAMS, entryCount),
        offsetof(NV2080_CTRL_GPU_PROMOTE_CTX_PARAMS, promoteEntry)
    };
    const uint32_t engines[] = {
        NV2080_ENGINE_TYPE_NVDEC0, NV2080_ENGINE_TYPE_NVDEC1,
        NV2080_ENGINE_TYPE_NVDEC2, NV2080_ENGINE_TYPE_NVDEC3,
        NV2080_ENGINE_TYPE_NVDEC4, NV2080_ENGINE_TYPE_NVDEC5,
        NV2080_ENGINE_TYPE_NVDEC6, NV2080_ENGINE_TYPE_NVDEC7,
        NV2080_ENGINE_TYPE_NVENC0, NV2080_ENGINE_TYPE_NVENC1,
        NV2080_ENGINE_TYPE_NVENC2, NV2080_ENGINE_TYPE_NVENC3
    };
    NV2080_CTRL_GPU_GET_CONSTRUCTED_FALCON_INFO_PARAMS info;
    memset(&info, 0, sizeof(info));
    info.numConstructedFalcons = 3;
    info.constructedFalconsTable[0].engDesc = 0x103000;
    info.constructedFalconsTable[0].ctxBufferSize = 0x8000;
    info.constructedFalconsTable[1].engDesc = 0x02000000;
    info.constructedFalconsTable[1].ctxBufferSize = 0x13000;
    info.constructedFalconsTable[2].engDesc = 0x303000;
    info.constructedFalconsTable[2].ctxBufferSize = 0x10000;
    FILE *f = fopen(argv[1], "wb");
    if (!f) return 2;
    if (fwrite(layout, sizeof(layout), 1, f) != 1 || fwrite(&info, sizeof(info), 1, f) != 1) return 3;
    for (size_t i = 0; i < sizeof(engines) / sizeof(engines[0]); ++i) {
        NV2080_CTRL_GPU_PROMOTE_CTX_PARAMS p;
        memset(&p, 0, sizeof(p));
        p.engineType = engines[i];
        p.hClient = 1;
        p.ChID = 8;
        p.hChanClient = 1;
        p.hObject = 7;
        p.virtAddress = 0x14000000;
        p.size = 0x13000;
        if (fwrite(&p, sizeof(p), 1, f) != 1) return 4;
    }
    return fclose(f) ? 5 : 0;
}
