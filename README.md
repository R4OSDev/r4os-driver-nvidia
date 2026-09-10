# NVIDIA.R4D

Original Apache-2.0 passive NVIDIA display driver for R4OS. Module 0.1.6;
hardware acceptance for roadmap 0.79.9 is open and offline preparation for
0.79.10 has started. This owner inventories NVIDIA display functions once through
the kernel PCI inventory. It does not initialize engines or take over scanout.
`IMAGE_SCOPE=none` keeps the module out of normal images. The boot framebuffer
and any existing display owner remain in control.

Subsystem IDs, PCI revision, HDA siblings, BAR addresses, standard interrupt
capabilities and readable current Resizable BAR sizes are reported separately
from unmeasured data. There are no BAR-sizing writes, bus-master changes, power
transitions, IRQ registrations, reset, DMA, firmware downloads or polling scans.
The sole bootstrap PCI entry, 10de:2504, permits three reads from two PMC boot
identity words under the real DriverApi owner when memory decode and power
state permit it. The 4 KB mapping is a minimum published identity-register
aperture, never a claimed measurement of the whole BAR. Only an actual GA106
identity selects `ga106-identity-only`; that profile admits no native writes.
Unknown PCI IDs are inventoried without MMIO. Failed or inconsistent identity
reads cannot authorize engine initialization.

VBIOS transport on real hardware remains unimplemented. PROM shadow selection
and PRAMIN remapping involve writes and are not advertised as passive reads.
The independent bounded ROM/BIT/DCB parser handles supplied immutable images,
checks lengths, supported versions and initialization/BIT checksums, and
resolves DCB 4.0/4.1 routes through CCB 4.1 and connector 3.0/4.0 tables.
Unsupported forms fail explicitly; parsing does not establish authenticity,
board compatibility, connected receivers, native display capabilities or
hardware acceptance. No BIOS code is executed.

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
NVKMS partial objects now have 333 and 47 unresolved imports after the clock
adapters below, including the remaining private heap and clock functions. `os-adapter-results.json` records the source/object
hashes, remaining imports and host-only acceptance. The ordinary fifteen-case
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
requires kernel 0.1.143 / DriverApi32. Other modes are rejected. `DISPLAYD /NVIDIA`
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
a blocked host filesystem operation. The `unit-test` step now has thirteen cases.

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
and records schema-2 os-adapter-results.json. The private provider is exercised
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
service integration; mutexes, semaphores, precise delays and hardware remain
separate work.
