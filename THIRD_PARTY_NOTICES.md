# Third-Party Notices

The driver, parser, tests and inspector are original R4OS Apache-2.0 code.
No NVIDIA RM/NVKMS/GSP implementation, firmware binary, Linux driver, or
envytools implementation is copied or linked into this passive module.

Register and binary-format facts were checked against the NVIDIA-published
register headers and DCB specification and the selected MIT-licensed BIOS
readers recorded in PROVENANCE.txt. Those upstream materials remain under
their original licenses in the separate workspace reference archive.
The synthetic parser fixtures are original test data, not extracted VBIOS.

Any future import of RM/NVKMS code or firmware must preserve its exact
source/binary license and provenance and update the distribution notices.

The offline firmware preparation tool reads explicitly supplied original
NVIDIA 570.144 files. Its separately prepared package contains both unchanged
GSP binaries and the byte-identical complete NVIDIA `LICENSE`, renamed to the
version-bound resource name recorded in `src/firmware-lock.json`. Those binary
files remain under NVIDIA's terms, never Apache-2.0. The driver module and this
source repository contain the pin metadata, not the proprietary binary files.
Neither the host preparation nor the parser executes firmware or an installer.
