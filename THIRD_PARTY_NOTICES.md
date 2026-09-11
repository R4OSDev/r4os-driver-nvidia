# Third-Party Notices

RM display-control source preparation (0.79.12, 2026-09-11):
gsp_display_rpc.zig preserves four complete original MIT source notices:
NVIDIA generated RPC structures(2008-2025), ctrl0073system(2005-2024),
ctrl0073specific(1993-2025), and Nouveau r535/rpc.c(2023 Red Hat).
Original R4OS bounded ownership/deadline/invalidation policy is Apache-2.0.
Eleven full hash-pinned originals accompany rm-control-20260911. The new
control code is host-linked preparation only; the entire production R4D
and all packaged notices remain byte-identical to NVIDIA0.1.44.


Internal GPIO metadata (NVIDIA 0.1.44, roadmap 0.79.12):
The decoder preserves complete original MIT notices from Nouveau bios/gpio.c
(2012 Red Hat) and gpio/base.c (2011 Red Hat), both Ben Skeggs. They also
extend the existing NVIDIA-CONNECTORS-LICENSE.txt to 5105 bytes in
the R4D and Distribution. All earlier 2620 notice bytes remain an exact
prefix. Fourteen full pinned originals accompany gpio-20260911; ga102.c
register/ownership code remains reference-only. Original R4OS copy, bounds,
matching and ambiguity policy is Apache-2.0. No live GPIO or firmware call.


Connector/CCB metadata (NVIDIA 0.1.43, roadmap 0.79.12):
The wiring decoder retains both complete Nouveau bios/i2c.c and conn.c
MIT notices, also in NVIDIA-CONNECTORS-LICENSE.txt and Distribution.
The R4OS bounded catalog/grouping is Apache-2.0. Eleven full hash-verified
originals accompany ExFiles/Reference/GFX/Nvidia/0.79.12/connectors-20260911.
NVIDIA DCB speed/function-mask facts and GSP/RM EDID ownership are documented
there. Firmware/RM display controls and register I2C remain reference-only;
no imported C implementation, native DDC transaction or live HPD is linked.


GA106 cursor and memory-LUT payloads (NVIDIA 0.1.39):
display_assets uses the original MIT C67D/C67E fields, NVKMS LUT layout
and pitch semantics, and Nouveau's GA102 cursor dispatch to its shared
packed-row check. Eight complete original notices remain in code and in
NVIDIA-DISPLAY-ASSETS-LICENSE.txt (10098 bytes), byte-identical in the
Distribution overlay. The display-assets-20260911 archive has 38 complete
hash-verified original files. Original PRAMIN system-target sources are
reference-only; system-memory reads are not implemented. Previous 28
resource payloads remain unchanged. Original R4OS ownership, validation
and backup policy stays Apache-2.0. Native recovery remains incomplete.

Earlier GA106 color/cursor state definitions (NVIDIA 0.1.38):
color_state follows the original MIT C67D/C67E/C67A method definitions,
GA102 armed mirror definitions, NVKMS indexed-table semantics and C6 cursor
HAL. Six complete original notices remain in code and in the new
NVIDIA-DISPLAY-COLOR-LICENSE.txt (7664 bytes), identical in Distribution.
31 complete pinned originals accompany display-color-20260911. The extra
Nouveau headc57d file is reference-only evidence for full-width OLUT norm;
its entire original notice remains in that file. Previous 27 module resource
payloads are unchanged. Original R4OS observation/lifetime/validation stays
Apache-2.0. Indexed tables and native display recovery are still incomplete.

Earlier GA106 display instance/context decoding (NVIDIA 0.1.37):
display_context adapts the pinned GA102 manual, RM v03 instance layout/hash
and NVKMS format/surface layout definitions under their original MIT terms.
Twelve additional complete per-source notices remain in the decoder and
NVIDIA-DISPLAY-CONTEXT-LICENSE.txt (14984 bytes), also packaged by Distribution.
28 complete verified originals accompany display-context-20260911: nine
Nouveau files, eighteen NVIDIA 570.144 files including COPYING, and one
GA102 manual. Generated RM dispatch is reference-only, with no copied
generated implementation. Previous 26 resource payloads remain unchanged.
R4OS capture, ownership and validation policy remain Apache-2.0. This work
does not provide native context programming, firmware start or full recovery.

Earlier GA106 window/plane observation (NVIDIA 0.1.36):
boot_scanout extends its MIT-attributed adaptation with explicit gv100/nv50
window mirror mapping, C67D/C67E definitions and Nouveau/NVKMS plane/offset
semantics. Five additional complete source notices remain in the code and
NVIDIA-BOOT-DISPLAY-LICENSE.txt (17645 bytes), identical in the driver and
Distribution. Fifteen full originals/pins accompany boot-planes-20260911.
All previous 25 resource payloads remain unchanged. R4OS observation,
consistency and lifetime policy remain Apache-2.0. ISO handles/offsets do
not establish physical addresses; native channels/recovery remain open.

Earlier GA106 boot display observation (NVIDIA 0.1.35):
boot_scanout.zig adapts Nouveau gv100 armed state/method mirrors (Red Hat,
2018, MIT) and NVIDIA 570.144 C67D fields (NVIDIA, 2020, MIT). Both full
original copyright/permission notices remain in the source. nv176 dispatch
and ga102 implementation confirm the supported profile. Ten complete
originals, including native UEFI console restoration context, accompany
boot-scanout-20260911. Full per-file MIT notices are packaged as
NVIDIA-BOOT-DISPLAY-LICENSE.txt in the nonallocated driver resource and the
Distribution legal directory/staging list. Original R4OS bounds, lifetime,
consistency and diagnostic policy remain Apache-2.0. Previous 25 resources
are unchanged; read observation is linked, native display programming is not.

Earlier GA106 BAR1/GMMU mapping and physical-function reader (NVIDIA 0.1.34):
bar1_walk.zig and bar1_reader.zig adapt the pinned NVIDIA MIT BAR1/RAMIN,
GMMU v2 and physical-function VREG definitions. TU102 PF adds 0xb80000;
BLOCK/BIND_STATUS are 0xb80f40/0xb80f50. Complete copyright and MIT terms
remain in the sources. The existing GM107 PRAMIN notices also apply.
Original R4OS bounds, reader, ownership and boot_mapping policy: Apache-2.0.
Nineteen complete pinned originals accompany bar1-reader-20260911. Full
source notices are packaged as NVIDIA-570.144-BAR1-LICENSE.txt in the
nonallocated driver resource and Distribution legal directory/staging list.
The resolver and reader are now linked into the explicit boot-check; all
previous 24 resource payloads are unchanged. No firmware/scanout execution.

Normal GA106 cold core stages (host qualified, 2026-09-11):
gsp_core extends its existing MIT-attributed adaptation using normal bootstrap
in kernel_gsp_tu102.c (NVIDIA2017-2024) and kflcnResetIntoRiscv_GA102 in
kernel_falcon_ga102.c (NVIDIA2021-2024). Existing full copyright lines and MIT
terms remain in the source. Bounded native admission/lifetime interfaces are
original R4OS Apache-2.0. Six complete pinned originals/notices accompany
cold-core-20260911. All execution remains unlinked; NVIDIA0.1.32 and its
24 packaged resource bytes are unchanged. Package complete additional core/
HS/result notices in module and distribution before executable linkage.

Normal GA106 Booter arguments/results (host qualified, 2026-09-11):
booter_result.zig adapts normal cold-load/unload argument/result semantics of
kernel_gsp_booter_tu102.c (NVIDIA2022-2024) and kgspIsWpr2Up_TU102 in
kernel_gsp_tu102.c (NVIDIA2017-2024), both MIT. Both original copyright lines
and complete terms remain in the adaptation. Bounded phases, DMA admission,
failure retention and real log-reader callbacks are original R4OS Apache-2.0.
Six complete pinned originals/notices accompany booter-result-20260911.
Normal execution remains unlinked; NVIDIA0.1.31 and all resource bytes are
unchanged. Before executable linkage, package complete additional core/HS/
FWSEC/Booter result notices in the module and distribution. This profile does
not implement suspend/resume or GC6 state and does not prove GPU quiescence.

FWSEC post-halt completion checks (host qualified, 2026-09-11):
fwsec_result.zig adapts the command-specific result checks of
kgspExecuteFwsec_TU102 in kernel_gsp_frts_tu102.c (NVIDIA2021-2023, MIT).
The full original notice is preserved in the adaptation. Register facts use
the original TU102 dev_bus.h (NVIDIA2003-2023) and dev_fb.h/dev_gc6_island.h/
dev_gc6_island_addendum.h (NVIDIA2003-2022), all MIT. Six complete pinned
originals, including COPYING, are archived under fwsec-result-20260911.
R4OS step, epoch/deadline and lifetime composition are original Apache-2.0.
These routines remain unlinked; NVIDIA0.1.31 and all resource/license bytes
are unchanged. Before native execution linkage, include the additional
complete core/HS/result notices in the module and distribution bundle.


PRAMIN / VGA-workspace capture (NVIDIA 0.1.29, 2026-09-11):
pramin.zig follows the GM107 BAR0 window semantics in kern_bus_gm107.c
(NVIDIA 2004-2024), its published dev_bus.h/dev_ram.h register definitions
(original NVIDIA copyright lines), and the VGA workspace profile/readback in
kernel_gsp_tu102.c and kern_disp_0400.c. Full original MIT notices and
copyright lines accompany the source. The 6,676-byte
NVIDIA-570.144-PRAMIN-LICENSE.txt resource includes all five complete notices;
Distribution carries the identical bytes. Stable ownership, bounded steps,
recovery and SDK/BO/MMIO binding are original R4OS Apache-2.0 code. The
executable PRAMIN capture is linked only through the explicit boot-check;
normal passive binding remains read-only. No original RM or Nouveau C is
linked. Full originals and dispatch evidence: vga-workspace-sources-20260911.
Pin: https://github.com/NVIDIA/open-gpu-kernel-modules/tree/8ec351aeb96a93a4bb69ccc12a542bf8a8df2b6f

Complete GA106 Falcon reset/TCM/upload composition (host, 2026-09-11):
falcon_run.zig composes the existing NVIDIA-derived core/HS executors with
original Apache-2.0 R4OS lifetime/admission. Its HWCFG IMEM/DMEM calculation
follows nvkm_falcon_oneinit in Nouveau nvkm/falcon/base.c (NVIDIA2016, MIT),
verified byte-identical to the earlier reference and now independently tied
to Linux commit 038d61fd642278bab63ee8ef722c50d10ab01e8f (v6.16). The full
original file, copyright and MIT terms are retained; no Linux code is linked.
https://raw.githubusercontent.com/torvalds/linux/038d61fd642278bab63ee8ef722c50d10ab01e8f/drivers/gpu/drm/nouveau/nvkm/falcon/base.c
SEC2 reset follows ksec2ResetHw_TU102 (NVIDIA2021-2023, MIT) through the shared
Falcon reset phases and explicitly selected GA102 SEC2 registers. Its full
copyright/notice is retained in gsp_core.zig; original reset/configuration
and generated dispatch remain in the 210-file NVIDIA reference set.
https://raw.githubusercontent.com/NVIDIA/open-gpu-kernel-modules/8ec351aeb96a93a4bb69ccc12a542bf8a8df2b6f/src/nvidia/src/kernel/gpu/sec2/arch/turing/kernel_sec2_tu102.c
39 core and34 HS values match original C macros. BCR VALID handling follows
the original conditional switch, with regression coverage in existing tests.
NVIDIA0.1.27 stays byte-identical; additional full MIT notices must join the
packaged module/distribution license bundle before executable linkage.
Archive falcon-run-20260911 has211 complete originals; no hardware execution.

GA106 HS Falcon execution (host qualified, 2026-09-11):
falcon_hs.zig adapts kgspExecuteHsFalcon_GA102 and s_dmaTransfer_GA102 from
kernel_gsp_falcon_ga102.c (NVIDIA 2021-2024), plus context-disable/CPU-start/
halt semantics in kernel_falcon_tu102.c (NVIDIA 2017-2024), under their MIT
license. GA102 published Falcon, second-page, FBIF, GSP and SEC2 headers and
HAL dispatch/configuration establish register identities and engine mapping.
The full MIT notice and original copyright lines are preserved in the
adaptation. R4OS admission, cooperative phases, deadline/epoch/lifetime and
SDK/MMIO binding are original Apache-2.0 interfaces. The complete pinned
570.144 snapshot was checked; 34 HS register values match the original C
macros. 210 complete original files/notices accompany falcon-hs-20260911.
These routines are not linked into NVIDIA0.1.27; module bytes and packaged
licenses remain identical. Before executable linkage, the additional full
MIT notices must join the module/distribution notice bundle. Host hardware
models are not GPU authentication or execution evidence.

NVIDIA 0.1.27 packages fourteen unchanged GA102 Booter Load/Unload
production artifacts from the original 570.144 bindata decoder export.
Header/signature preparation in booter.zig adapts kernel_gsp_booter.c
(NVIDIA CORPORATION & AFFILIATES, 2021-2023, MIT); its full original notice
is retained. SEC2 fuse semantics come from kernel_sec2_ga100.c. Resource,
deadline, DMA lifetime and admission interfaces are original R4OS Apache-2.0.
NVIDIA-570.144-BOOTER-LICENSE.txt contains full COPYING and four per-source
MIT notices; the 24,640 bytes are identical in R4D and Distribution. Sources,
artifact lengths/hashes and all notices are bound in firmware-lock.json.
Resource binaries remain original; selected signatures are installed only
into private runtime CPU/DMA images. No GPU authentication/start is claimed.
Nine complete originals including dispatch/HS/core context are preserved in
gsp-booter-20260911. The additional HAL context is reference material; core,
sequencer and firmware boot operations are not newly linked or executed.

Earlier complete-run notice:

NVIDIA 0.1.26 adds original Apache-2.0 complete-run ownership code and retains
the admitted descriptor appVersion. Firmware and full packaged notices remain
byte-identical. The gsp_core.Resume value type introduces no executable core,
sequencer or boot-event linkage; those methods remain host-qualified only.
Complete descriptor source and COPYING: gsp-run-memory-20260911.

Earlier core/MMIO notice:

The host-qualified `gsp_core.zig` adapts the pinned GA102/TU102 Falcon/GSP
implementations (NVIDIA 2017-2024,2021-2024) and published GA102 headers
(2003-2021,2017-2021,2003-2022,2003-2024), NVIDIA CORPORATION & AFFILIATES.
It preserves the full MIT permission/disclaimer and all copyright lines.
R4OS cooperative state, ownership and `gsp_sequencer_port` are Apache-2.0.
Thirty register constants match complete original C headers; the algorithm
tests use host hardware models. 205 complete originals/notices are retained
in gsp-core-20260911. No original HAL binary or these new executable methods
are linked into NVIDIA 0.1.25. The unchanged packaged notice bundle must gain
all new full notices before executable linkage and distribution.

Earlier sequencer notice:

The host-qualified `gsp_sequencer.zig` adapts opcode/operation semantics from
rmgspseq.h (2019-2020), kernel_gsp.c (2019-2024) and the executed timeout
contract in gpu_timeout.c (1993-2023), NVIDIA CORPORATION & AFFILIATES, from
the same 570.144 pin. It retains the full MIT notice/copyright; original R4OS
admission, scheduling, port and lifetime logic is Apache-2.0. The existing ABI
verifier uses complete original command types/macros for all nine opcodes.
The 185 full original dependencies/sources/notices are in gsp-sequencer-20260911.
Interpreter/dispatch execution is not linked into NVIDIA.R4D0.1.25; no native
MMIO/Falcon/SEC2 handler or original RM implementation is linked. The current
notice resource remains unchanged and must gain every new full notice before
executable linkage in the module and Distribution.

The host-qualified `gsp_boot_events.zig` adapts the six boot-event layouts and
selection from pinned g_rpc-structures.h (2008-2025), ctrl2080nvd.h (2004-2023),
rpc_global_enums.h and kernel_gsp.c (2019-2024), NVIDIA CORPORATION & AFFILIATES.
The source retains the full MIT permission/disclaimer and copyright lines;
original R4OS admission, ownership and deadlines remain Apache-2.0. The
181 complete original dependencies/sources/notices accompany the
gsp-boot-events-20260911 archive with exact hashes and official source URLs.
The optional existing ABI verifier creates six frames with original generated
C types and checksum; it runs only on host memory. No boot-event code is linked
into NVIDIA.R4D0.1.25, and its33543-byte boot notice remains unchanged. Future
executable linkage must include all additional full codec/transport/event
notices in the module and Distribution. There is no new firmware or RM linkage.


Original R4OS driver, parser, adapter, test and inspector code is Apache-2.0.
The attributed layout/metadata adaptations and selected original NVIDIA
headers described below retain their MIT terms. No full NVIDIA RM/NVKMS host implementation, Linux driver or
envytools implementation is linked into the R4OS driver. The packaged module
also contains the two original GSP firmware containers and the production
GA102 boot image/descriptor described below.

Register and binary-format facts were checked against the NVIDIA-published
register headers and DCB specification and the selected MIT-licensed BIOS
readers recorded in PROVENANCE.txt. Those upstream materials remain under
their original licenses in the separate workspace reference archive.
Fixture firmware bodies and signatures are synthetic; selected measured table
metadata is regression data documented in PROVENANCE.txt.

Module0.1.25 links the queue-header inspector from `src/gsp_ring.zig` in
the explicit pre-submission boot-check. The complete pinned msgq.c/msgq_priv.h
MIT notices (2018-2019 NVIDIA CORPORATION & AFFILIATES) already accompany
the unchanged33,543-byte boot notice bundle and firmware lock (twelve inputs).
The byte-identical notice is in the R4D and Distribution. The new QueueLease
storage/SDK binding is original Apache-2.0 code. Original RM/msgq C remains
host-only, and executable GSP codec/Session methods are not yet linked.
The gsp-dma-port-20260911 archive retains four complete pinned sources/notices
and links the earlier full original source set and generic DMA provider.

The host-qualified `src/gsp_transport.zig` adapts ordered payload/cursor
publication and protocol sequence advancement from the pinned NVIDIA570.144
message_queue_cpu.c (2019-2024 NVIDIA CORPORATION & AFFILIATES). Its complete
MIT notice is retained in the source; original R4OS port, deadline, receipt
and failure interfaces are Apache-2.0. Four complete original source/notice
files accompany gsp-transport-20260911, linked to the prior full reference set.
The model does not execute original RM or a real GPU. It is not linked into
NVIDIA.R4D0.1.24; the distributed bundle must include all new notices on linkage.

The host-qualified `src/gsp_ring.zig` adapts geometry, swap routing and
cursor arithmetic from the pinned msgq.c/msgq_priv.h (2018-2019 NVIDIA
CORPORATION & AFFILIATES) under the complete retained MIT notice. Original
R4OS admission/copy interfaces are Apache-2.0. The existing optional ABI
verifier executes original msgq operations only on host memory. All 179 full
original dependency/source/license files accompany the gsp-ring-20260911 archive.
This layer is not linked into NVIDIA.R4D0.1.24; packaged notices are unchanged.

The host-qualified `src/gsp_message.zig` adapts the pinned message framing
and checksum from message_queue_priv.h (2019-2022), message_queue_cpu.c
(2019-2024), g_rpc-message-header.h (2008-2025), rpc_headers.h (2017-2024)
and rpc_common.c (2020-2024), NVIDIA CORPORATION & AFFILIATES. It retains the
complete MIT notice and copyright lines; original R4OS admission is Apache-2.0.
The existing optional host ABI verifier includes the complete original types
and checksum implementation. All 177 original dependencies/source/notice
files are preserved byte-for-byte in the gsp-message-20260911 reference archive.
Original checked assertions are enabled; host failure callbacks abort.
This codec is not yet linked into NVIDIA.R4D 0.1.24. The distributed license
bundle is unchanged and must gain these complete notices before linkage.

Module 0.1.24 links `gsp_init.zig`, which adapts first-boot field assignment
from the same pinned NVIDIA Libos/RM initialization and message-queue sources.
It retains the complete NVIDIA MIT notice and copyright lines for
libos_init_args.h (2018-2022), gsp_init_args.h (2020-2024), kernel_gsp.c and
message_queue_cpu.c (2019-2024), message_queue_priv.h (2019-2022), and
msgq.c/msgq_priv.h (2018-2019). Original R4OS validation is Apache-2.0.
The existing optional ABI verifier now compiles the original msgq implementation
against its unchanged headers and compares the complete initialized image.
All full original sources/notices accompany the separate gsp-init-20260911
archive. The current 33,543-byte boot notice bundle adds the complete notices
from all six newly linked source inputs to the prior bundle. It is identical
in NVIDIA.R4D and Distribution; original msgq C remains a host verifier only.

Module 0.1.23 links the MIT-attributed layout and WPR metadata code described
below. It adds the byte-identical 24-KB production GA102 boot image and its
84-byte descriptor exported from the pinned original generated source
`g_bindata_kgspGetBinArchiveGspRmBoot_GA102.c` (copyright 2016-2022 NVIDIA
CORPORATION). `src/firmware-lock.json` pins these files and their exact source.
The `NVIDIA-570.144-GSP-BOOT-LICENSE.txt` resource contains full unchanged
COPYING plus complete MIT notices from the boot, layout/metadata and init
sources. Module 0.1.24 pins twelve inputs. The identical 33,543-byte file is in
Distribution's R4OS/LICENSES and adjacent Legal output. Original R4OS resource
and DMA ownership code remains Apache-2.0; the original decoder is not linked.
The ignored `BootFirmware/` package is prepared only from verified exported
files and complete original source notices. Neither this repository nor the
module relabels upstream code or firmware under the R4OS license.

The WPR metadata encoder in `src/gsp_wpr.zig` retains
NVIDIA's complete MIT notice for the field layout/assignment adapted from
`gsp_fw_wpr_meta.h` (2021-2024) and `kernel_gsp_tu102.c` (2017-2024),
NVIDIA CORPORATION & AFFILIATES. Original R4OS admission and validation are
Apache-2.0. The existing optional ABI probe compiles the complete original
WPR header and compares the C structure with the actual Zig encoding.
All original references and notices accompany the separate
`ExFiles/Reference/GFX/Nvidia/0.79.10/wpr-metadata-20260911` checkpoint.
The earlier host checkpoint did not change NVIDIA.R4D 0.1.22; its metadata
encoder is now linked in the explicit boot-check path of 0.1.23.

The GSP layout calculation in `src/gsp_layout.zig` adapts the
MIT-licensed NVIDIA 570.144 layout and heap algorithms from
`kernel_gsp_tu102.c` (copyright 2017-2024), `kernel_gsp.c` (2019-2024) and
`gsp_fw_heap.h` (2022-2024), NVIDIA CORPORATION & AFFILIATES. That file retains
the original copyright lines and full MIT permission/disclaimer. Original
R4OS admission checks and interfaces remain Apache-2.0. This calculation is
now linked into NVIDIA.R4D 0.1.23 with its complete source notices retained.

The boot descriptor validator and scatter/gather Radix3 encoder are original
R4OS code based on the format facts in `rmRiscvUcode.h`,
`gsp_fw_wpr_meta.h`, `libos_init_args.h` and the same pinned RM implementation.
The production boot image and descriptor were initially external reference
inputs; 0.1.23 includes their unchanged bytes with the complete notice above. All complete
sources, notices, hashes and original bootstrap metadata accompany
`ExFiles/Reference/GFX/Nvidia/0.79.10/gsp-memory-layout-20260911`.
No additional original C header is packaged by this integration.

The 0.1.21 GSP/VRAM preflight is original R4OS code. Register facts come
from the same pinned NVIDIA sources and Nouveau's MIT-noticed
nvkm/falcon/base.c (NVIDIA copyright 2016) in the Linux 7.2.4 reference.
Those complete original files and notices remain in the separate
`ExFiles/Reference/GFX/Nvidia/0.79.10/gsp-preflight-20260911` archive.
No additional upstream implementation, header or binary is linked or vendored.

The 0.1.20 FWSEC DMA mapper and load-parameter validator are original R4OS
code. The pinned NVIDIA GA102 loader, GA106 HAL dispatch and register headers
are reference material, retained unchanged with their complete notices in
`ExFiles/Reference/GFX/Nvidia/0.79.10/fwsec-dma-20260910`. No additional NVIDIA
implementation, header or firmware is linked or vendored by this checkpoint.

Since module 0.1.9, `ThirdParty/Nvidia570.144` vendors 19 unchanged original
MIT header files (236,096 bytes) from NVIDIA Open GPU Kernel Modules 570.144,
commit 8ec351aeb96a93a4bb69ccc12a542bf8a8df2b6f. `ORIGIN.json` lists each
path, size and SHA-256 and binds them to the single firmware/source pin.
All per-file notices remain intact; `COPYING` is the complete upstream file,
including the terms for other parts of the source package. No source package
license is replaced by the R4OS license.

`LICENSES.txt` collects the full copyright and permission notice of every
selected header plus the complete original COPYING. NVIDIA.R4D carries this
file byte-for-byte as `NVIDIA-570.144-HEADERS-LICENSE.txt`; Distribution carries
the identical file in `/R4OS/LICENSES` and its adjacent `Legal` directory.
The headers compile the R4OS memory/clock/semaphore/wait/format/log C adapters in the actual
module and in the separate source-build subset. They are not
a redistribution of the complete RM/NVKMS implementation.

Any future import of RM/NVKMS code or additional firmware must preserve its exact
source/binary license and provenance and update the distribution notices.

The firmware preparation tool reads explicitly supplied original NVIDIA
570.144 files. Its local prepared package contains both unchanged
GSP binaries and the byte-identical complete NVIDIA `LICENSE`, renamed to the
version-bound resource name recorded in `src/firmware-lock.json`. Those binary
files remain under NVIDIA's terms, never Apache-2.0. The public source
repository excludes the prepared `Firmware/` directory. The canonical
`module.R4MF` packages the verified originals and complete license together
with `NVFW-LOCK.json` in NVIDIA.R4D's nonallocated resource section. The R4OS
Distribution overlay also carries the byte-identical complete license under
`/R4OS/LICENSES/NVIDIA-570.144-LICENSE.txt` and beside its images.
Neither preparation nor CPU-side validation executes firmware or an installer.

The optional `prepare-bootstrap` step compiles four original generated bindata
archives from the same verified source snapshot. Their full original MIT
notices, source files and complete COPYING accompany the 26 byte-identical
decoded artifacts. The host executable links NVIDIA's original utilGz decoder
in `src/nvidia/src/lib/zlib/inflate.c`; its NVIDIA and Jean-loup Gailly/Mark
Adler zlib notices and accompanying header are retained verbatim. The R4OS
exporter and scripts are original code. No original decoder implementation is vendored or linked into the R4D.
The new separate prepare-boot-firmware step provisions two of the already
exported artifacts as the explicit 0.1.23 resources described above.

The same optional step extracts the unchanged FWSEC command typedefs from
`kernel_gsp_frts_tu102.c` into a private derived header, preserving the complete
original MIT notice and source path. A host-only C/Zig comparison uses those
types and the pinned original `nvtypes.h`. The derived header, original source,
fuse/HAL references and complete COPYING accompany the reference package.
The comparison code and target CPU preparer are original R4OS implementations;
no extracted NVIDIA typedef or RM routine is newly linked into NVIDIA.R4D.

The optional `build-rm` host step compiles an explicitly supplied, hash-pinned
original NVIDIA Open GPU Kernel Modules 570.144 source snapshot under scratch.
It retains the complete upstream `COPYING`, per-file notices and SoftFloat's
`COPYING.txt` in that private tree. The temporary `nvUnixVersion.h` overlay
preserves the original NVIDIA notice and adds only the R4OS version-string
platform guard. No RM/NVKMS implementation or compiled RM object is installed
in NVIDIA.R4D by this step, and none is vendored into this repository.
The scripts and digest metadata are original R4OS work. A future redistribution
of the compiled objects must carry the corresponding original notices and
third-party terms; a successful source-only build grants no new license.

That private build now also contains the original eight shader payloads,
their XZ containers and readonly object wrappers. The shader files remain
covered by the source package's original `COPYING` and matching metadata.
No shader payload is vendored here or installed in NVIDIA.R4D by this step.
The host verifier links the source package's XZ Embedded decoder, whose files
state public-domain terms and credit Lasse Collin and Igor Pavlov, with the
original MIT-noticed NVIDIA memory-hook headers. Its full original sources
and notices remain in the verified scratch snapshot. XZ Utils is an external
host prerequisite and is not redistributed by this driver repository.
