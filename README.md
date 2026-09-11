# NVIDIA.R4D

Passive NVIDIA display driver for R4OS. Module 0.1.24; original R4OS code is
Apache-2.0, with attributed MIT layout/metadata code, selected original MIT
headers and separately licensed firmware.
Passive hardware acceptance for roadmap 0.79.9 is complete on GA106/A1,
subsystem 1458:4074, VBIOS 94.06.2f.00.d6. Preparation for 0.79.10 continues.
This owner inventories NVIDIA display functions once through
the kernel PCI inventory. It does not initialize engines or take over scanout.
`IMAGE_SCOPE=none` keeps the module out of normal images. The boot framebuffer
and any existing display owner remain in control.

The host-qualified `gsp_ring.zig` layer admits command/status geometry and
computes swap routing using each side's own RX-header offset. A zero peer
header means not ready; unknown flags, invalid offsets/counts and out-of-range
cursors are refused. The pinned queues hold 256 KB each, normally 63 slots
with one slot reserved. Transfers cover at most 16 slots and two contiguous
spans, including wraparound. Gathering accepts a complete validated message;
scattering leaves the CPU queue shadow unchanged on admission failure.
Neither operation publishes a cursor, sequence, acknowledgement or live link.

The existing owner step now passes 42 cases. Eight fixtures match actual
original msgq linking, slot lookup, submit and consume operations, including
all four swap-flag combinations, RX offsets 32/64 and wraparound. This is host
validation only. At the ring checkpoint, DriverApi33 synchronized entire mappings: live shared
queues cannot use its bidirectional whole-buffer bounce copy. Before live
integration, require direct coherent mappings with ordered publication or
a proven range-sync contract. Pre-submission staging remains valid. No module,
packaged license or OssiPC change was needed for this checkpoint.

The host-qualified `gsp_message.zig` codec now frames the pinned cleartext
GA106 GSP/RPC messages: a 48-byte outer header, 32-byte RPC header and at most
16 complete 4-KB slots. Prefix admission bounds both element count and RPC
length before gathering; complete-record admission checks exact slot extent,
version/signature, zero eight-byte padding, checksum and expected sequence.
RPC function/result and auth/AAD fields remain opaque; a valid checksum is
neither authentication nor a dispatch decision. Unused final-slot bytes are
not payload. Encoding rejects overlapping input and leaves output unchanged
on admission failure, using caller storage without a hidden allocation.

The existing owner step passes 41 cases. Six boundary fixtures, including the
64-KB maximum, match complete original NVIDIA C structures and the original
checksum byte-for-byte. Checked-build assertions remain enabled; host-only
failure callbacks abort. The optional ABI step retains the previous complete
init/WPR/SB/FRTS comparisons. The codec requires stable CPU snapshots; it owns
no ring, cursor, acknowledgement, DMA synchronization or RPC/IRQ dispatch.
NVIDIA.R4D 0.1.24 and its packaged licenses remain byte-identical. Future codec
linkage must add its full original notices to the pinned resource bundle.

Module 0.1.24 extends the explicit `OPTION NVIDIA mode=boot-check` diagnostic.
After the actual GA106 board, fuse and FWSEC preflight, it admits the pinned
24-KB boot image, 84-byte descriptor and complete license from the currently
loaded R4D. Resource generation, exact lengths, hashes and a monotonic deadline
are checked before any boot input is exposed. It then admits the GA10X GSP
container and composes the existing image and boot-pack owners described below.
Five DMA mappings hold the image, tables, bootloader, signature and 256-byte
WPR metadata. Seven further mappings hold Libos/RM arguments, five logs and
the shared queues, disjoint from every retained image, boot-pack and FWSEC
span. FWSEC exclusions use their actual byte extent, without imposing the
new GSP pages' alignment on them. Final synchronization precedes each report.
Init mappings close before boot-pack/image mappings and then FWSEC; a failed
release retains that dependency chain for shutdown. All close during init. No address is submitted to the GPU, no VRAM is reserved
or changed, and the normal passive mode remains the default.

`src/firmware-lock.json` is the single source for the boot artifacts and their
complete provenance. The module now contains eight nonallocated resources.
The 33,543-byte license resource includes the unchanged full COPYING and
eleven complete MIT notices covering the boot source and adapted layout,
metadata and initialization code. Distribution carries the identical notices in R4OS/LICENSES
and its adjacent Legal directory. CPU hash admission is not GPU authentication.

Provision already exported, pinned boot files without rebuilding RM or the
original decoder, using absolute paths and a fresh scratch directory:

    ./Build.sh prepare-boot-firmware -- -SourceDirectory ORIGINAL_RM -BootstrapDirectory REFERENCE_PACKAGE -ScratchDirectory WORKSPACE/Temp/boot-resources

This verifies the original source records and exported bytes and atomically
creates the ignored `BootFirmware/` package. It refuses a differing existing
output. The ordinary module build verifies all three new resources together
with the existing firmware package. No network or installer is used.

OssiPC accepted module 0.1.24 boot/init preparation on 2026-09-11: twelve
GSP/boot/init mappings plus retained FWSEC, 36 GSP segments and
1 queue segments, 0 bounced init mappings. Final synchronization and
dependency-ordered cleanup succeeded; bootfb 800x600/generation 1/reset 0
and all 14 services stayed available. Batches 15/16 and two reboots restored
the exact original passive configuration. Full package roundtrip hashes,
installed checks, inventory and unique runtime markers establish this proof;
no independent installed-module hash or fresh visible-image/audio acceptance.
The first package was rejected for an incorrect kernel requirement before
staging; the temporary packaging substitution was fixed, module unchanged.

Historical OssiPC acceptance of module 0.1.23 on 2026-09-11: all three boot resources
matched, four image mappings contained 36 actual segments, and the
contiguous boot pack needed no bounce. Final synchronization and complete
cleanup succeeded. Bootfb remained 800x600 at generation 1/reset 0; all
14 automatic services ran. A second SYSUPD batch/reboot restored the exact
350-byte passive configuration. Package roundtrip hashes, installed checks,
inventory and unique runtime records establish the update; no separate
installed-module download or fresh visible-image/audio acceptance was made.

`gsp_init_storage.zig` now owns this 844-KB image through the existing R4D
heap/DMA facade. One contiguous mapping covers both argument pages, five
contiguous mappings cover the logs, and one mapping supports up to 64 queue
segments. Arguments are to-device; logs and queues are bidirectional. Backing
is zeroed before any initial map synchronization and all seven mappings are
synchronized again after encoding. Only then is a complete report published.

The shared monotonic deadline brackets each operation. Partial pins/maps and
failed in/out release descriptors remain owned. Cleanup retires all mappings
in reverse order, then all pins, then the single resident allocation, using
the cached shutdown API. It does not own the other boot allocations supplied
as exclusion spans. A future execution owner must prove actual quiescence
before releasing any memory that has been submitted to the GPU.
The existing host step passes 40 cases, including one new grouped case with
17 storage scenarios and exact full-buffer bounce synchronization. Module
0.1.24 connects this owner to boot-check; normal passive mode does not stage it.

The separately qualified `gsp_init.zig` encoder prepares the pinned GA106 first-boot
Libos and RM arguments, five 64-KB release log areas and two 256-KB message
queues. The complete caller-owned image needs 844 KB. Its queue table includes
its own page: 129 physical page addresses, then command/status queues. The
command ring has 63 slots and 62 usable entries; its initial swap-RX request
is not a completed negotiation. Status metadata remains zero for GSP to create.

All span sizes, full 49-bit addresses, alignment and overlap are checked
before output changes. Queue pages may be physically scattered; log and
argument spans must be contiguous. Other retained boot spans can be excluded.
The log put pointer stays zero, with 16 actual page addresses immediately
following it. LOGINIT is first; numeric id8 tags use the original encoding.
The normal single-GPU profile keeps PM/profiler fields zero and selects the
original DMEM-stack default. All padding and unused entries are cleared.

The existing host ABI probe compares every byte with the original C types
and executes the original `msgqInit`/`msgqTxCreate` on host memory. The existing
owner step passes 40 cases; `inspect-gsp-layout` reports these requirements
without inventing DMA addresses. Byte-sized exclusion admission adds four
negative variants to the existing encoder case; all 844 KB still match the
original-C comparison. Queue linking, receive synchronization, RPC/IRQ and
hardware handoff remain open. Status headers stay zero and firmware-ready
remains false; no live GSP producer or completion is inferred from staging.

The preceding module 0.1.22 extended the existing `firmware-check` diagnostic mode with
actual GSP image DMA staging. The admitted GA10X `.fwimage` is copied into
separate, page-aligned resident backing with its three-level Radix3 tables.
The pinned image needs 63,676,416 bytes including 132 KB of tables. Four
independently owned mappings obey the DriverApi's 16 MB/64-segment limits;
up to 256 discontiguous segments are supported overall. No GPU receives the
root address, and normal passive mode does not allocate this large backing.

Each initial map may synchronize to a bounded bounce buffer, so backing is
zeroed before mapping. After the actual device addresses have been encoded,
all mappings are explicitly synchronized again before the root is reported.
The total preparation deadline is checked before and after the task-context
operations; it does not promise cancellation of a blocked kernel callback.
Partial maps, pins and failed release descriptors retain their exact owner.
Cleanup closes every mapping, then every pin, then the resident allocation;
the admitted source container stays alive through the preparation call.
The existing mode line is `OPTION NVIDIA mode=firmware-check`; it remains
an explicit diagnostic and falls through to the same passive board inventory.
This older mode stages only the GSP image and its page tables. The new
boot-check mode also owns bootloader, signature and WPR metadata. VGA recovery,
actual VRAM ownership and firmware execution remain open.

The separately qualified `gsp_wpr.zig` supplies a pinned 256-byte first-boot
metadata template and checked DMA address binding. `inspect-gsp-layout`
now reports the unbound little-endian template with zero device addresses,
boot count, clock flags and Booter verification marker. Encoding live bindings
requires the complete disjoint GSP scatter/gather spans plus contiguous boot
and signature spans; an optional contiguous crash queue uses the original
union layout. The encoder confers no memory ownership or authentication.
The existing explicit bootstrap ABI probe compares all 256 encoded bytes
with the original NVIDIA C structure, including padding and the crash union.
The original host checkpoint left NVIDIA.R4D 0.1.22 unchanged; module 0.1.23
now uses this encoder after the actual preflight.

`gsp_boot_storage.zig` now composes the image owner with one page-aligned
32-KB boot pack: 24 KB boot image, 4 KB signature, then a 4-KB page containing
the 256-byte metadata and zero padding. One contiguous mapping, optionally
bounced, covers the pack. The full pack, including its metadata page, must
not overlap any GSP span. A second synchronization publishes the completed
metadata after actual addresses exist. Pack cleanup precedes image cleanup;
failed releases retain both owners for retry. The caller admits the complete
firmware inputs first. This owner was first tested through the R4D facade on the host and is now
used by the explicit boot-check mode with admitted module resources.

The CPU-only FWSEC catalog resolves BIT 'p', full 32-bit token pointers and
the original RM expansion-ROM bias. V2 loader and V3 signed-image descriptors,
code/data bounds, sparse signature-version masks and DMEM command interfaces
are checked within the validated PCI ROM chain. At most eight FWSEC variants
are reported with image/descriptor/signature hashes. Signature lookup does
not authenticate firmware.
The opaque V3 reserved word is preserved, including the nonzero value observed
on GA106. Command input is bounded within loaded DMEM; firmware output and
workspace addresses are opaque declarations with no CPU slice accessor.
A rejected FWSEC catalog leaves valid passive board discovery usable
and emits at most 2 KB of explicitly unvalidated CPU-copy evidence.
`inspect-vbios` schema 2 also handles IFR envelopes and reports the same catalog
for a supplied file; file inspection never claims physical GPU acceptance.
On OssiPC, module 0.1.18 successfully cataloged the two actual V3 entries in
VBIOS 94.06.2f.00.d6 and released all probe resources; bootfb remained active.

Module 0.1.19 additionally admits two read-only fuse pages on measured GA106
with sufficient current BAR0 extent. It reads `82074c` and the selected
ucode's `8241c0 + 4*(id-1)` twice within a one-second deadline. NVIDIA's GA100
HAL selects debug/production with bit zero and computes the signature version
as highest set bit plus one on the complete version register. Missing,
ambiguous or unsupported entries and unavailable signatures preserve passive
startup. Only V3 target 7, engine mask `400`, flags 1 and ucode IDs 1..16 qualify.

After closing those mappings, a separate resident CPU allocation receives a
copy of the selected image, its 24-byte SB input, initial command `19` and
384-byte signature. Every bound and overlap is checked before writing. The
ROM and firmware output/workspace declarations remain untouched. The image
is hashed before DMA staging and freed during init. FRTS encoding is covered
separately, including its
48-byte ABI and zero padding; actual FRTS allocation and execution remain open.
Failed unmap/collect/free retains its exact owner for shutdown retry.
The 0.1.19 OssiPC check confirmed debug-disable `00000001`, ucode 9 version raw `00000003`
(version 2), production entry 9 and the 384-byte signature at ROM `4153c`.
Its 59,904-byte SB image is prepared and released successfully. Bootfb stays
at generation 1/reset 0, buffer/queue resources balance and all 14 automatic
services run. This is CPU preparation; no GPU firmware has been started.

Module 0.1.20 stages that immutable image through the existing R4D pin/map
API. A 256-byte-aligned CPU allocation is mapped coherently to the device
under the Falcon's 49-bit address limit. Exactly one physical segment is
required; the kernel can provide its bounded bounce fallback for fragmented
pages. Mapping performs the device synchronization. CPU pointers are never
substituted for DMA addresses. Both original GA102 transfer ranges (also used
by GA106), 256-byte blocks, 24-bit TCM offsets, IMEM virtual bias, V3's absent
DMEM virtual tag and PKC placement are validated before publishing a plan.
No GPU address is submitted and no firmware is executed. Falcon reset,
authentication and recovery still need native implementation.
Cleanup retires the mapping, its pin and then CPU backing; each failed release
retains the exact descriptor for shutdown retry. SB is the original unload
command that restores pre-OS applications, not proof of GSP startup. The native
startup path needs an owned FRTS/WPR region, FWSEC-FRTS and the GSP boot chain.

Module 0.1.21 adds a bounded, read-only GA106 preflight. At most six measured
BAR0 pages supply thirteen named registers: Falcon capacity/state, RISC-V,
devinit-published VRAM size, WPR2 bounds, display fuse and VGA workspace.
Disabled or inaccessible capability bits prevent reads of their dependent
windows. Two identical passes must finish within one monotonic second;
protected, missing or changing values never authorize execution.
The staged IMEM/DMEM ranges are checked against actual TCM capacity. The
current VGA reservation is retained; a needed relocation is only reported.
The GA106 HAL does not use GA100's MMU-lock registers. RESET_READY is a hint
because NVIDIA documents a hardware erratum. MMIO cleanup precedes DMA and
CPU release; failed cleanup retains the owner for shutdown retry. The result
is an observation, never an engine-reset, VRAM-allocation or recovery grant.

The optional `inspect-gsp-layout` host step validates the production GA102
GSP boot image and its 84-byte RISC-V descriptor against the same central
570.144 pin, then calculates the GA106 bare-metal first-boot layout from a
recorded preflight and the admitted GSP `.fwimage` section. Descriptor ranges,
overlap, first-boot state, WPR reuse, 40-bit VRAM bounds, heap limits and all
alignments are checked before publishing a new report. It does not install
another module or modify the GPU. That host checkpoint kept NVIDIA.R4D 0.1.21 unchanged.

    ./Build.sh inspect-gsp-layout -- PREFLIGHT.json GSP.bin BOOT.bin DESC.bin OUTPUT.json

Supply absolute paths. The snapshot schema is 1, with `recorded_utc`, unsigned
`pci_vendor`, `pci_device`, `pmc_boot0`, `pmc_boot1` and `raw`. The latter has
thirteen unsigned `values` in `fwsec_state.Register` order and a `present` bit
mask. It is an archived observation, not a current ownership proof. JSON inputs
are limited to 16 KB; firmware sizes and hashes must match the pin. Existing
outputs and path aliases are refused. An actual OssiPC input/report, original
boot files and complete references are preserved under the workspace's
`ExFiles/Reference/GFX/Nvidia/0.79.10/gsp-memory-layout-20260911`.

For the recorded 12 GB board, the proposed top reservation is 192 MB, with a
128 MB GSP heap, 1 MB non-WPR heap, 1 MB metadata reservation, 1 MB FRTS and
the admitted image/boot bytes and alignment padding. The 256-byte WPR metadata
size is distinct from its 1 MB reservation. The current VGA base `0x10e0000`
requires relocation to `0x2fffe0000` before this proposed layout can be used.
Only the top 256 MB may be assumed pre-scrubbed by this GA106 firmware path.
An active WPR, busy engine, another chip or an unsupported boot profile is
rejected; recovery/retry margins, vGPU and registry overrides are not modeled.

`gsp_radix.zig` prepares the original three-level, 4 KB Libos page-table format
using the caller's actual, retained DMA segments. It supports up to 256
discontiguous spans in logical order, validates their address limits and
overlap before any output write, copies the admitted image once and clears
only tables and final-page padding. CPU pointers never become page entries.
The actual `.fwimage` needs 15,513 data pages and 33 table pages (132 KB), a
combined allocation of 63,676,416 bytes. This is a requirement, not an allocated
GPU resource. A future runtime owner must supply and retain mappings, perform
device synchronization and prove quiescence before release. The host report
assigns no DMA addresses. Native boot, metadata handoff and recovery remain open.

The explicit `prepare-bootstrap` step exports 26 original GA102 GSP/Booter and
TU102 SEC2 reference artifacts from the same 570.144 source pin. It verifies a
private source snapshot before compiling the original data initializers and
decoder, compares the decoded bytes with bounded .NET Deflate, and preserves
original names, hashes, family mappings and complete notices. It publishes a
complete directory atomically; an existing different output is refused.
The same step mechanically extracts the pinned FWSEC C typedefs with their
complete MIT notice, compiles them, and compares both command buffers against
the real Zig encoder. `fwsec-abi.json` records sizes, offsets and byte equality.
Use absolute paths, with scratch under the workspace's `Temp/` and output on
the same filesystem, outside the source and driver repositories:

    ./Build.sh prepare-bootstrap -- -SourceDirectory ORIGINAL_RM -ScratchDirectory WORKSPACE/Temp/bootstrap -OutputDirectory REFERENCE_PACKAGE

The host step neither adds module resources nor measures GPU fuses.
Its original decoder runs only on data covered by the complete source pin;
it is not a decoder for arbitrary supplied compressed input.

The current native CPU port also provides the nine original RM/NVKMS
formatting and logging declarations. Integer varargs, truncation lengths,
bounded input scans and driver-owned severity records are checked by the
existing `unit-test` and explicit SMP4 runtime profile. The complete R4D has
51 C adapters and 13 actual private providers; the separate full-source partial
links still have 325 RM and 46 NVKMS undefined symbols. GSP initialization,
native scanout and HDMI audio remain unimplemented.

Subsystem IDs, PCI revision, HDA siblings, BAR addresses, standard interrupt
capabilities and readable current Resizable BAR sizes are reported separately
from unmeasured data. There are no BAR-sizing writes, bus-master changes, power
transitions, IRQ registrations, reset, GPU DMA submissions, firmware downloads or polling scans.
The sole bootstrap PCI entry, 10de:2504, permits three reads from two PMC boot
identity words under the real DriverApi owner when memory decode and power
state permit it. The 4 KB mapping is a minimum published identity-register
aperture, never a claimed measurement of the whole BAR. Only an actual GA106
identity selects `ga106-passive`; that profile admits no native writes.
Unknown PCI IDs are inventoried without MMIO. Failed or inconsistent identity
reads cannot authorize engine initialization.

When the actual GA106 and current ReBAR extent cover the published PROM
aperture, the owner reads the one-MB range twice into resident CPU memory.
Both copies must match within a bounded deadline. It never changes PCI ROM
shadowing or a PRAMIN window. Unknown identities and unmeasured bounds cannot
reach this path. IFR 1/2/3 envelopes and bounded NVIDIA private subimages are
interpreted before the immutable ROM/BIT/DCB parser. The parser
checks lengths, supported versions and initialization/BIT checksums, and
resolves DCB 4.0/4.1 routes through CCB 4.1 and connector 3.0/4.0 tables.
Transport/parse failures preserve the boot framebuffer; failed cleanup retains
the exact mapping/allocation until shutdown can release it. Display generation
is explicitly mapped from measured GA106 to the pinned GA102 display reference;
this is not a query of running display-engine classes or a modeset capability.
Unsupported forms fail explicitly; parsing does not establish authenticity,
board compatibility, connected receivers, native display capabilities or
hardware acceptance. No BIOS code is executed.

Executable x86/EFI images must match the expected PCI device. Private e0
images with NV/NPDS or NV/RGIS envelopes retain their NVIDIA vendor check;
their container device field is not used as the board's PCI identity.
Rejected ROMs produce bounded, explicitly unvalidated header records from
the CPU copy (at most 4 KB per adapter), without additional MMIO or partial
topology publication.

Use `Build.bat` (Windows) or `./Build.sh` (Linux), with the same arguments:

    ./Build.sh unit-test
    ./Build.sh inspect-vbios -- INPUT.rom OUTPUT.json 2504
    ./Build.sh prepare-firmware -- -SourceDirectory EXTRACTED_FILES -ScratchDirectory WORKSPACE/Temp/nvidia
    ./Build.sh

The separate `build-rm` step compiles the selected original RM/NVKMS source
lists into two **incomplete relocatable objects** and reports their unresolved
symbols, TLS, initializers and allocated relocations. It does not install a
driver or execute GPU code:

    ./Build.sh build-rm -- -SourceDirectory ORIGINAL_SOURCE_TREE -ScratchDirectory WORKSPACE/Temp/nvidia-rm [-Jobs 4] [-XzPath XZ_EXECUTABLE]

Use absolute paths. Supply the extracted 570.144 source revision named by
`src/firmware-lock.json`. `Tools/Rm/Sources.json` pins all 3,156 source, header,
build and license inputs to that revision. A private snapshot is verified
before compilation; missing, modified or extra inputs are rejected. The source
tree, firmware package and installed NVIDIA.R4D remain untouched. Every attempt
gets a fresh directory below scratch, retaining its source notices and logs.
The compiler comes from the normal SDK build graph. PowerShell 7 provides the
same orchestration on both hosts; no vendor build scripts or Linux OS emulation
are involved. Execution on a Windows host still requires verification.
The shader step requires XZ Utils, already included in the Debian DevKit host
prerequisites. It resolves `xz` from PATH, or accepts an explicit absolute
`-XzPath` on either host, including a Windows `xz.exe`. It never downloads a
compressor or executes a GPU program.

The only temporary source adaptation adds `NV_R4OS` to the version-string
header's OS guard, preserving its original notice. Component include order,
defines, C/C++ source lists and SPDM-specific flags remain separate. PIC and
freestanding target flags replace the Linux kernel code model. Explicit `-g0`
avoids implicit compiler debug metadata; source path remapping removes scratch
paths from code and data. The RM partial link uses the original export roots
and linker script. This is not the final loader-compatible link: OS callbacks,
SPDM crypto, duplicate/global symbol handling and
the R4OS runtime integration remain open. Details and evidence are recorded in
the workspace's `Docs/Drivers/GrafikFirmware07910.txt/.json`.

The eight original NVKMS shader payloads are now compressed with the upstream
XZ settings (`--extreme --check=none`, one thread), decoded with the original
NVIDIA XZ Embedded code, and compared byte-for-byte with the pinned originals.
The generated `ProgramHeapSize` metadata must match exactly. Binary streams
preserve every byte on both hosts; subprocess deadlines cover a blocked input
pipe as well as normal execution. Readonly ELF objects provide the original
sixteen start/end symbols and are linked into the NVKMS partial object.
`shader-results.json` records input, metadata, compressor and object hashes.
The verifier uses real host memory functions for the original allocation/copy
hooks; it is not an R4OS driver runtime or a GPU execution test. Shader bytes
and compiled objects stay in the private source-build tree.

The source build also compiles `src/rm/os_memory.c` and `nvkms_memory.c`
against the original OS interface headers: seventeen actual CPU allocation,
copy, fill, move, compare and string adapters. Integer-register copies avoid
recursion through RM's own `gcc_helper.c` memcpy/memset wrappers and preserve
exact byte spans without SIMD. The private `r4nv_heap_allocate/free` imports
remain unresolved in those separate partial objects. `src/rm_heap.zig` now
implements the real resident provider in NVIDIA.R4D using DriverApi30; the final
combined RM/NVKMS/provider link is still pending.
These adapters do not supply synchronization, DMA, MMIO or GPU initialization.

`Tests/RmMemory.c` runs as part of this explicit source build, with a real host
test allocator, injected allocation failures and protected boundary pages.
Linux x86_64 executes the exact freestanding adapter objects used in the
partial links; Windows compiles the same C sources for its native host ABI.
The host allocator is never linked into a target object. The resulting RM and
NVKMS partial objects now have 329 and 48 unresolved imports after the
semaphore adapters below, including the remaining private providers and the
required nonreturning native-fault boundary. `os-adapter-results.json` records the source/object
hashes, remaining imports and host-only acceptance. The ordinary seventeen-case
`unit-test` and installed NVIDIA.R4D remain separate from this source port.

The optional last inspector argument is the expected hexadecimal PCI device
ID. The inspector reads at most 1 MB (1024 KB), writes JSON only on success,
and records the source hash, checksum scope, active routes and unverified
hardware status. It never obtains ROM data from a device itself. Both build
starters use shared PowerShell 7 orchestration and local `Settings.R4S` SDK,
Contract, Libraries, DevKit and artifact mappings.

The normal module build requires the explicitly prepared originals described
below. Inspector and unit-test steps work before firmware is provisioned.

In an explicit R4OS Test image, configure `DRIVER=NVIDIA` and optionally
`OPTION NVIDIA mode=passive`. `mode=firmware-check` additionally verifies both
packaged GSP containers in CPU memory before continuing the passive probe.
`mode=runtime-check` explicitly exercises CPU heap calls from init and a real
worker, validates close admission, and stops init before PCI. Its two leftover
CPU allocations must be reclaimed by the actual failed-load cleanup. This mode
requires kernel 0.1.146 / DriverApi33 with the optional 88-byte thread table. Other modes are rejected. `DISPLAYD /NVIDIA`
replays complete NVIDIA boot records, with no additional hardware access.
Distribution's `graphics-test Test nvidia-passive` runs an explicit short SMP4
absence/fallback check with the existing graphics harness. It requires the
current NVIDIA, DISPLAYD and normal Test artifacts. It is not a hardware test.
`graphics-test Test nvidia-runtime` checks the CPU probe, quiesced kernel frees
and usable bootfb in that same bounded SMP4 harness.

The C heap bridge preserves 16-byte alignment with a small private handle
prefix and forwards exact checked u64 lengths. A failed void C free retains
the actual kernel allocation for retry or owner cleanup. Host lifecycle tests
exercise the real bridge, an injected free failure, close, unavailable old API
and lengths above 4 GB without allocating a huge host buffer. The kernel owns
residency and per-start identity; GPU/DMA mapping and synchronization remain
separate. No RM mutex, GSP transport or native graphics execution is supplied
by the CPU heap implementation.

See `DOCUMENTATION.de.txt`, `PROVENANCE.txt`, `LICENSE`, `NOTICE` and
`THIRD_PARTY_NOTICES.md`. RM/NVKMS/GSP 570.144 is the selected future bringup
baseline. The module now carries both original GSP containers and their full
license as resources; it does not link the RM/NVKMS host implementation.

The same `unit-test` step also runs the actual driver init/shutdown functions
against the real SDK facade and a simulated DriverApi. Unadmitted callbacks
trap; unknown-device refusal, repeated init/shutdown, failed public unmap and
retained private partial mappings are exercised. This verifies software
lifetime decisions without claiming physical MMIO or board acceptance.

Firmware preparation uses the single `src/firmware-lock.json` for RM version,
upstream commit, exact artifact lengths/hashes, license and container-family
mapping. The module carries that lock as `NVFW-LOCK.json` in its nonallocated
R4M0 resource section. With DriverApi29 it verifies this exact loaded lock before PCI inventory; rejection leaves the display fallback usable. Embedded
R4D resources require kernel 0.1.138 or newer to remain outside image memory.
Use kernel 0.1.140 or newer for the firmware-check CPU storage/cleanup path.

    ./Build.sh inspect-firmware -- INPUT.bin ga10x REPORT.json
    ./Build.sh prepare-firmware -- -SourceDirectory EXTRACTED_FILES -ScratchDirectory WORKSPACE/Temp/nvidia [-OutputDirectory PACKAGE]

Supply the previously extracted original `gsp_ga10x.bin`, `gsp_tu10x.bin` and
`LICENSE` from the pinned NVIDIA 570.144 installer. Neither command downloads
files or executes the installer. Use absolute paths for preparation directories;
scratch and output must share a filesystem for atomic publication. The complete
NVIDIA license accompanies both byte-identical binaries. An existing package
must match exactly; a different package is never repaired in place. The default
output is this owner's ignored `Firmware/` directory, which the canonical
`module.R4MF` consumes. An explicit different output prepares a standalone
package and does not change the manifest or the normal build's source paths.
Normal builds recheck all three pinned originals before packaging; missing or
corrupt inputs fail without changing a previously installed NVIDIA.R4D.

The inspector uses the same allocation-free loader component intended for the
R4D adapter: at most 64 KB per step, caller-owned final storage, exact SHA-256,
bounded ELF64/LE/ET_REL/EM_RISCV section checks, exact `.fwversion`, and 4096-byte
signature sections for the selected release's families. Reports are created
exclusively after success. Opaque signature bytes are preserved; GPU signature
verification and hardware compatibility are not established by this check.
Host-file deadlines are checked before and after I/O, not by forcibly cancelling
a blocked host filesystem operation. The `unit-test` step now has seventeen cases.

RM/NVKMS integration, board-specific FWSEC, GSP bootstrap/RPC and hardware
fallback acceptance remain open. Packaged and CPU-verified firmware does not
establish an operational GPU driver or GPU-side signature authentication.

Kernel 0.1.139 adds the optional DriverApi29 resource table. The real passive
driver now reads and compares NVFW-LOCK.json through that table, with a
two-second deadline, before enumerating PCI. The old DriverApi28 prefix
still supports the passive probe, with firmware loading explicitly disabled.
Missing, mismatched, short or timed-out lock reads on the new path reject init.
The same SMP4 absence/fallback profile requires the loaded-lock proof.

`firmware_resources.Reader` is the SDK adapter for `firmware.Load`: it checks
the loaded lock, exact resource name/size and common module generation, then
passes only that opaque resource handle to bounded reads. Caller-owned final
CPU storage and full SHA/ELF checks remain required. The current normal module
contains the lock, complete license and both original GSP containers. No GPU
firmware is booted or DMA submitted by this checkpoint. Driver resources use
the captured disk module source; preload bytes have no retained source and
are rejected explicitly. Resource references do not guarantee immutable disk
contents. Final pinned hashes remain mandatory. Storage cleanup can outlive
the absolute read deadline while the caller buffer remains retained.

`firmware_storage.Storage` owns a system-memory buffer and CPU map through the
existing SDK memory table. It loads at most 64 KB per step directly into one
final buffer, with a 30-second absolute budget per container. Only full hash,
ELF and version validation returns a borrowed ready view. Close invalidates
all views before unmap, release and collection. The table is retained across
shutdown admission closure; failed VM/TLB cleanup retains ownership even after
the public reference has been dropped. Repeated close is safe. No DMA mapping,
GPU boot, native register write or display takeover occurs.

The existing Distribution graphics harness provides `nvidia-firmware`,
`nvidia-firmware-missing` and `nvidia-firmware-corrupt`. All use four vCPUs and
fresh private images, never real hardware. The failure variants change only a
private module copy; the canonical artifact and prepared originals stay intact.
The successful guest verifies 63571696 and 28542040 bytes through 971 and 436
resource reads, releases both CPU buffers, and leaves bootfb usable. The R4D
image is 44 KB; its large resource payload remains outside that allocation.

Monotonic clock integration (0.79.10)
-----------------------------------
DriverApi31 appends the existing 80-byte MonotonicClockInfo snapshot without
changing the old 608-byte prefix. R4SYS and R4D use one kernel mapping of the
same source, nanosecond origin, resolution and quality flags. The actual
rm_clock.zig provider caches the existing read-only resource clock for fast
timestamp reads, avoiding a full metadata snapshot in polling hot paths.
Resolution queries read current metadata, including degraded source changes.
Unavailable or malformed readings latch the provider unavailable until rebind;
UINT64_MAX is an error marker, never an invented timestamp.

os_clock.c implements os_get_current_tick, os_get_current_tick_hr and
os_get_tick_resolution in nanoseconds. nvkms_clock.c converts valid readings
to microseconds and preserves the error marker. Both RM tick functions use
the same high-resolution source; tick resolution describes that actual source.
The explicit source build tests these exact target objects in Tests/RmClock.c
and records the clock acceptance in schema-3 os-adapter-results.json. The private provider is exercised
separately by the actual NVIDIA.R4D runtime-check: 64 sequential clock reads
from both init and a real worker, followed by a scheduler wait and progress
check. The combined RM link remains pending. No UTC, CPU-frequency, delay,
mutex, semaphore, interrupt or firmware-start callback is faked. Future native
dispatch must honor the latched clock fault and its own bounded work budget;
upstream value-only time functions cannot cancel arbitrary RM loops.

Dedicated driver tasks (0.79.10)
------------------------------
The explicit runtime-check also uses DriverApi32's dedicated tasks with full
module FPU state and guarded kernel stacks. Four CPU callbacks verify real
task/start identities, heap contents and monotonic time while the original
shared BSP Driver Work lane is deliberately occupied. One callback stays on
the BSP; the other three explicitly permit SMP placement. This test requires
actual progress on at least two CPUs, not a fixed affinity or throughput.

The same short diagnostic checks finite join/poll, self-join rejection,
cooperative stop, cancellation of one join without stopping its target, stale
handles and exact task retirement. Parent close wakes a dedicated sleeper,
rejects new starts/allocations and allows its existing heap buffer to be freed.
Three returned task records remain for generic driver cleanup. Failed waits
retain the module; a diagnostic assertion after confirmed callback quiescence
reports failure without vetoing safe cleanup. Normal passive starts create no
tasks. No RM/NVKMS thread adapter or combined RM link is claimed by this CPU
service integration; precise delays, the remaining native OS callbacks and
hardware remain separate work.

Resident semaphores (0.79.10)
----------------------------
The explicit runtime-check additionally negotiates DriverApi33. Three actual
waiters verify FIFO single-permit handoff; four dedicated tasks perform 256
protected read/modify/write operations, deliberately sleeping while holding
their binary semaphore to force contention. Finite timeout, counter overflow,
stale handles and destruction with active waits are checked in the same run.
A stopped task stays blocked on its uninterruptible semaphore until shutdown
provides a real permit. New creation closes; existing operations remain usable.
The diagnostic retires its own tasks before the preceding thread probe's
accounting, and leaves two semaphore records for generic kernel cleanup.
Normal passive startup still creates neither tasks nor semaphores.

Private RM/NVKMS semaphore bridge (0.79.10)
------------------------------------------
`rm_semaphore.zig` supplies five private C-ABI hooks through DriverApi33 and
the resident CPU heap. Each opaque pointer owns a real aligned CPU box with
a kernel semaphore handle. Creation uses the full u32 counter range; zero
timeout tries once and UINT64_MAX waits for a real permit. Close rejects new
objects while cached operations can finish existing waits and free backing.
The caller must quiesce every user before freeing; the cookie is a corruption
check for live pointers, not arbitrary-address or double-free validation.

Failed kernel destruction retains both objects. If the semaphore is gone but
its CPU free fails, a retry frees only that box, without destroying a stale
handle. Unexpected failures latch provider availability until rebind; cleanup
remains usable. The shared heap adds an internal per-operation result while
preserving its existing void C ABI. No kernel or public API change is needed.

`os_semaphore.c` implements twelve original RM entrypoints, including the two
context predicates; `nvkms_semaphore.c` supplies four NVKMS entrypoints. Both
compile against the pinned original headers. Conditional RM mutex acquisition
still requires a sleepable context, whereas conditional semaphore acquisition
and a single release support resident IRQ context. This is a counting
semaphore, not an IRQ spinlock or a recursive/task-owned mutex.

The void-returning free/up/down paths require `r4nv_native_fault` on failure.
It is explicitly noreturn. The dedicated-Task boundary described below now
supplies it in the ordinary R4D; the separate full RM/NVKMS partial objects
still leave private providers unresolved. No failed down fabricates a permit.
The 180-check hosted acceptance executes the exact freestanding C objects on
Linux, including 25 failure transfers into its host-only setjmp/longjmp fixture.
That fixture never enters a R4D. Windows sources are cross-built, not executed.

The actual private Zig provider is tested separately in the existing SMP4
runtime-check: four dedicated callbacks, 128 protected updates across real
scheduler waits, bounded timeout, busy destruction and actual close/stop
handoff. All its CPU boxes and task records are freed before the preceding
diagnostics' accounting. The previous FIFO, 256-update, heap and clock probes
remain required. Normal passive startup allocates no semaphore. C semaphore
execution and its native fault boundary are covered below. The combined RM
link and actual GPU/IRQ hardware acceptance remain open.

Actual C memory/clock integration (0.79.10)
-----------------------------------------
The ordinary NVIDIA.R4D now links the four memory/clock C source files and
`src/rm/cpu_probe.c` through the SDK's canonical mixed Zig/C R4D manifest path.
All 21 RM/NVKMS memory, string and clock symbols use the real private Zig heap
and clock providers. No hosted allocator, timer, Linux implementation, full
RM/NVKMS object or synchronization-fault stub enters that target link.

`ThirdParty/Nvidia570.144` contains the 19 byte-identical original MIT headers
needed by all linked memory, clock and semaphore adapters. Its
`ORIGIN.json` records every file hash and the shared firmware/source pin.
Git preserves this package byte-for-byte on Windows and Linux; automatic
text and line-ending conversion is disabled for the complete vendor tree.
The normal build verifies that package before C compilation. Missing, changed,
extra or mismatched inputs fail; prepared proprietary firmware is verified
separately before packaging. Unit tests do not require the firmware binaries.

`COPYING` is the complete original source-package license file. `LICENSES.txt`
preserves every selected header's full notice plus COPYING, and is packaged
as `NVIDIA-570.144-HEADERS-LICENSE.txt` in the nonallocated resource section.
The same file accompanies distribution images inside and beside the image.
There are five resources: source/firmware lock, header notices, firmware
license, GA10x firmware and TU10x firmware. Header files remain unchanged.

The existing explicit SMP4 runtime-check calls the actual C probe from both
init and Driver Work. It checks allocation limits, zero sizes, alignment,
unaligned copies with canaries, overlapping moves, strings and the ns-to-us
clock bridge, then requires zero live allocations and successful close.
The success record says `native-c=OK adapters=21 ... link=actual` only after
both real contexts complete. Normal passive startup does not run this probe.
The C semaphore sources also enter the ordinary module in 0.1.10 through
the native invocation and failure boundary described next.
The separate full RM/NVKMS partial-object evidence remains unchanged; GSP,
GPU authentication, native scanout and HDMI acceptance remain open.

Native semaphore callbacks and synchronous abort (0.79.10)
---------------------------------------------------------
All sixteen original-header semaphore adapters now join the same R4D link.
`rm_native.zig` starts caller-owned invocations as explicitly abortable
dedicated Tasks. No fixed invocation pool or global serialized native lane
is introduced. A first private fault latches its operation/result, refuses
new ordinary invocations and aborts only the executing callback with -76001.
Queued invocations check admission again on entry; already admitted peers
must finish cooperatively. Cleanup invocations require an explicit flag and
do not clear the fault. Rebind resets it only after the previous owner closes.

The optional DriverThreadApi slots at offsets 72 and 80 (table size 88,
still version 1) are required for this path. Passive startup remains available with older
tables. Kernel 0.1.145 restores an ordinary SysV caller frame, then completes
and retires the Task through its existing lifetime machinery. No C/Zig defers
run across an accepted abort. The native owner retains memory, semaphore,
lock and DMA obligations until it has quiesced every peer. Timeout retains
the callback and module; it does not revoke execution or GPU access.

Only negative synchronous self-aborts on opted-in Tasks are accepted with
interrupts enabled, no kernel lock/critical section/wait and exactly the
initial Task unwind guard. Rejected platform calls return a status. A void
native failure outside that admitted boundary is a programming/ABI violation
and traps. This is no CPU-exception, hung-loop or arbitrary GPU recovery path.

The existing runtime-check calls all sixteen real C adapters. A C waiter
blocks on a zero-count semaphore, then a second C callback attempts Busy
free: its following instruction must remain unexecuted, while two CPU
allocations (145 bytes including private prefixes) and the waiter stay live.
New ordinary dispatch is rejected. Explicit cleanup supplies one real C
permit, joins and retires the waiter, frees its semaphore through C and
releases memory through the status-bearing private heap owner. All counts
return to the preceding probes' baseline; the native failure stays latched.
Partial diagnostic shutdown also retains resources until every peer retires.

Thin Zig Task entries call the actual C functions directly. This avoids
external function-address GOT relaxation while retaining the packager's
strict ABS64/REL32 contract. No relocation check is weakened. The original
headers, firmware, notices and five nonallocated resources are unchanged.
The separate full RM/NVKMS link, GSP/RPC, GPU initialization, native display
and HDMI require further implementation and eventual hardware acceptance.

Native waits and phase deadlines (NVIDIA 0.1.11, 0.79.10)
------------------------------------------------------
`os_delay_us`, `os_delay`, `os_schedule`, `nvkms_usleep` and `nvkms_yield`
use the actual `r4nv_wait_ns` / `r4nv_schedule` providers in the ordinary R4D.
There are now 42 original-header C adapters and 12 private target providers.
The five callbacks use the existing 19 byte-identical headers, with no new
vendor implementation in the module. The pinned Linux timing implementations
serve as primary behavior references; the R4OS implementation is original.

Microsecond RM waits remain busy; longer sleepable waits give whole ticks to
the scheduler and check the actual monotonic clock after every return. The
remaining fraction uses bounded clock polling. NVKMS waits below 1000us are
busy; larger waits require a sleepable context. Full 64-bit conversion rejects
overflow before dispatch, without the upstream 12-bit millisecond mask.
IRQ busy requests above 20ms are refused. A periodic-event-only clock cannot
support busy waits while interrupts are disabled. Frozen/regressed/invalid
clock readings close ordinary native admission, never authorize early success.
The stalled-read budget detects lack of progress, not calibrated elapsed time.

Each ordinary caller-owned Invocation now requires an absolute monotonic
deadline, checked before start, on entry, inside waits/yields and after normal
return. `current_request` identifies its context from the actual running Task;
concurrent calls have independent immutable deadlines, with no TLS/per-CPU
pointer cache or fixed invocation pool. A cooperative deadline returns -76002;
clock loss returns -76003. A nonzero callback result remains intact. Explicit
cleanup may use deadline zero when the clock is unavailable. No mechanism
forcibly terminates a busy upstream loop or revokes GPU/DMA access.

Dedicated sleeping Tasks observe cooperative stop as NV_ERR_SIGNAL_PENDING;
phase expiration maps to NV_ERR_TIMEOUT. Void NVKMS errors enter the existing
noreturn native fault boundary. Init/work can use valid sleepable legacy tick
waits, whose elapsed time is still checked after wake. Actual yield requires
a dedicated Task because the legacy waitTicks(0) ABI is explicitly a no-op;
missing yield context fails instead of claiming scheduling occurred.

The existing SMP4 runtime-check exercises all five C callbacks, including a
4100ms NVKMS wait, proves actual blocked sleep-queue enrollment before stop,
runs concurrent 250ms/5s phase deadlines and rejects an already expired call.
All Task records retire before the older semaphore/abort/close probes. Four
pure policy cases join the existing owner step (21 cases total); the separate
original-source build checks 58 C conversions/statuses and 13 noreturn faults
against the exact freestanding adapter objects on Linux. Partial links now
include eight adapter objects; their private runtime providers intentionally
remain unresolved. Full RM/NVKMS/GSP, native display and HDMI remain open.

Kernel0.1.148 / DriverApi34 now provides optional byte-range synchronization
for existing DMA mappings, qualified by its kernel owner and the ordinary
EXAMPLE fixture. The GSP runtime must still order payload/cursor publication,
limit each transfer to exclusively owned bytes and prove quiescence before
unmap. NVIDIA0.1.24 does not yet bind the message/ring layers to live DMA.
