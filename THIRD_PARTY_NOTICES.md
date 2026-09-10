# Third-Party Notices

The driver, parser, adapters, tests and inspector are original R4OS Apache-2.0
code. The selected original NVIDIA MIT headers described below retain their
own terms. No full NVIDIA RM/NVKMS host implementation, Linux driver or
envytools implementation is linked into the R4OS driver. The packaged module
also contains the two original GSP firmware containers described below.

Register and binary-format facts were checked against the NVIDIA-published
register headers and DCB specification and the selected MIT-licensed BIOS
readers recorded in PROVENANCE.txt. Those upstream materials remain under
their original licenses in the separate workspace reference archive.
Fixture firmware bodies and signatures are synthetic; selected measured table
metadata is regression data documented in PROVENANCE.txt.

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
exporter and scripts are original code. No bootstrap binary or original
decoder implementation is vendored into this repository or added to the R4D.

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
