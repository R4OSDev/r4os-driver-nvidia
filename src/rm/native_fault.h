/* Mandatory, still unresolved boundary for native operations without a status
 * return. A failed down must never return as though it had acquired a permit.
 * The future native dispatcher must supply this before RM/NVKMS can be linked
 * into a running R4D. There is deliberately no target stub or global panic. */
#ifndef R4NV_NATIVE_FAULT_H
#define R4NV_NATIVE_FAULT_H
#include "nvtypes.h"
#define R4NV_FAULT_SEMAPHORE_FREE 1U
#define R4NV_FAULT_SEMAPHORE_DOWN 2U
#define R4NV_FAULT_SEMAPHORE_UP   3U
void r4nv_native_fault(NvU32 operation, NvS32 result) __attribute__((noreturn));
#endif
