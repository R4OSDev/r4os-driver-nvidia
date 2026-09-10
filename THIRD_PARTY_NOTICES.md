# Third-Party Notices

The driver, parser, tests and inspector are original R4OS Apache-2.0 code.
No NVIDIA RM/NVKMS host implementation, Linux driver, or envytools
implementation is copied or linked into the R4OS driver code. The packaged
module contains the two original GSP firmware containers described below.

Register and binary-format facts were checked against the NVIDIA-published
register headers and DCB specification and the selected MIT-licensed BIOS
readers recorded in PROVENANCE.txt. Those upstream materials remain under
their original licenses in the separate workspace reference archive.
The synthetic parser fixtures are original test data, not extracted VBIOS.

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
