# NVIDIA.R4D

Original Apache-2.0 passive NVIDIA display driver for R4OS. Roadmap 0.79.9
is in progress. This owner inventories NVIDIA display functions once through
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

    ./Build.sh
    ./Build.sh unit-test
    ./Build.sh inspect-vbios -- INPUT.rom OUTPUT.json 2504

The optional last inspector argument is the expected hexadecimal PCI device
ID. The inspector reads at most 1 MB (1024 KB), writes JSON only on success,
and records the source hash, checksum scope, active routes and unverified
hardware status. It never obtains ROM data from a device itself. Both build
starters use shared PowerShell 7 orchestration and local `Settings.R4S` SDK,
Contract, Libraries, DevKit and artifact mappings.

In an explicit R4OS Test image, configure `DRIVER=NVIDIA` and optionally
`OPTION NVIDIA mode=passive`; any other mode is rejected. `DISPLAYD /NVIDIA`
replays complete NVIDIA boot records, with no additional hardware access.
Distribution's `graphics-test Test nvidia-passive` runs an explicit short SMP4
absence/fallback check with the existing graphics harness. It requires the
current NVIDIA, DISPLAYD and normal Test artifacts. It is not a hardware test.

See `DOCUMENTATION.de.txt`, `PROVENANCE.txt`, `LICENSE`, `NOTICE` and
`THIRD_PARTY_NOTICES.md`. RM/NVKMS/GSP 570.144 is the selected future bringup
baseline; this passive stage embeds none of those components or binaries.

The same `unit-test` step also runs the actual driver init/shutdown functions
against the real SDK facade and a simulated DriverApi. Unadmitted callbacks
trap; unknown-device refusal, repeated init/shutdown, failed public unmap and
retained private partial mappings are exercised. This verifies software
lifetime decisions without claiming physical MMIO or board acceptance.
