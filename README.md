# NVIDIA.R4D

NVIDIA display driver for R4OS, passive by default. Module 0.1.64; original R4OS code is
Apache-2.0, with attributed MIT layout/metadata code, selected original MIT
headers and separately licensed firmware.
Passive hardware acceptance for roadmap 0.79.9 is complete on GA106/A1,
subsystem 1458:4074, VBIOS 94.06.2f.00.d6. The 0.79.10 software stage is complete; physical native qualification remains separate.
The default path inventories NVIDIA display functions once through
the kernel PCI inventory. Explicit diagnostic/start modes are described below.
Starting with R4OS 0.79.9, `IMAGE_SCOPE=slim` includes the current module in
Slim and Full. The standard configuration selects `mode=passive`; no GPU
firmware is executed. The boot framebuffer and existing display owner remain
in control. Full includes DISPLAYD for subsequent hardware diagnostics.

Roadmap0.79.12 is complete in software (NVIDIA0.1.64, 2026-09-12).
The actual Device retains PCI-bound VBIOS wiring, correlates RM heads,
encoders and physical records, and publishes unambiguous receiver types.
DCB4.1 pad masks are separate from SORs. External GPIO tables retain their
own headers, bus identities and type-specific functions; no external code
is relabeled as an internal HPD input. Virtual/ambiguous paths stay explicit.
51 existing owner groups, module build, schema6 inspector and complete
license staging pass. Physical follow-up remains ExFiles/Reports/OssiGPU.txt.
Evidence: Docs/Drivers/GrafikEmpfaenger07912.txt/.json.

The following dated checkpoints describe the earlier implementation stages.

AUX receiver acquisition (NVIDIA 0.1.63, 2026-09-12):

Confirmed static DP resources use bounded DPCD and I2C-over-AUX reads on
the actual shared RM channel. Full EDID blocks, short replies, write-status
DEFER handling, original deadlines and explicit MOT/STOP retirement reach
the common catalog. Eight original C layout vectors, 51 existing owner
tests, the module build and complete license staging pass. The actual Device
fixture publishes 4096 AUX bytes and checks the bounded diagnostic lines.
Physical port/GPIO correlation remains open; DP training and MST retain
their later roadmap stages. OssiPC remains untouched.

Bounded DDC acquisition (NVIDIA 0.1.62, 2026-09-12):

The actual RM graph now owns an optional NV40_I2C child. An incomplete or
rejected RAW EDID can use confirmed DDC ports to read up to 32 complete
blocks through a bounded FINN codec. Segment pointers, three-attempt limits,
original deadlines, whole-generation invalidation and explicit no-data/error
results are integrated into the existing shared parser and receiver catalog.
Six independent original NVIDIA serializer vectors, 51 existing owner tests,
the module build and exact license staging pass. DP AUX and complete physical
port correlation remain software work. Hardware qualification remains in
ExFiles/Reports/OssiGPU.txt; passive operation is still the default.

Observed head routing (NVIDIA 0.1.61, 2026-09-12):

The existing RM channel now reads total head count and each active display
assignment, including firmware state. It repeats the observation around the
port pass and discards changed generations. Rejected heads stay unknown;
zero means successfully observed inactive. These observations never become
mode capabilities or routing leases. Existing 51 owner cases and the module
build pass; fixed layouts are verified against complete pinned 570.144 headers.
No additional guest run. Details: Docs/Drivers/GrafikEmpfaenger07912.txt/.json.

Receiver catalog publication (NVIDIA 0.1.60 / Kernel 0.1.153, 2026-09-12):

A coherent native generation now replaces all receiver records atomically in
R4DRAW. The optional 48-byte driver output table registers an owner-bound
metadata source without an execution queue. Source limits/routing stay zero;
receiver timings never authorize a modeset. HPD, failure and stop invalidate
published and borrowed data even while GPU backing remains retained.
DISPLAYD /RECEIVERS reads this same catalog and parser without hardware work.
The default stays passive; gsp-start requires the new table before submission.
Software evidence and remaining transport work: Docs/Drivers/GrafikEmpfaenger07912.txt.
Physical follow-up: ExFiles/Reports/OssiGPU.txt, section 0.79.12.

Native topology and receiver acquisition (NVIDIA 0.1.59, 2026-09-12):

After RM/IRQ setup, the actual runtime queries every supported display's
connector/resource/bus relationships and RAW EDID through its existing graph.
The shared R4GFX parser retains modes, CTA audio and explicit missing, invalid,
incomplete or rejected data. Each generation has one ten-second budget and
fixed resident storage for up to 32 display IDs; there is no second queue.

Per-receiver masks and a final supported-mask reply/ACK/drain protect the
complete generation. Interleaved events invalidate all candidates. HPD/DP
also invalidates already returned data and coalesces a later refresh, with
at least one second between acquisitions. CPU sequencer/lockdown use the
display-semantic bridges; ambiguous failures retain receipts and GPU backing.
The original private snapshot is now published by the 0.1.60 bridge above.
Extended DDC/AUX transport, native scanout and HDMI audio remain unfinished.

Both targeted host runs pass 51/51 existing tests; both module builds pass.
The final run followed an additional cross-receiver/final-mask consistency
check found during review. 42 fields from original C declarations and exact
legal staging pass. No new test group, guest or hardware run. 22 upstream files
and the unchanged parser sources are archived under
ExFiles/Reference/GFX/Nvidia/0.79.10/gsp-outputs-20260912.

Thermal review: Nouveau disables its legacy thermal owner under GSP-RM. No
suitable public temperature-read contract was found in the reviewed 570.144
sources; PERF_GET_POWERSTATE reports AC/battery. Existing zero boost flags
and the three-entry boot registry stay unchanged. No temperature, fan,
voltage or clock setting is fabricated. Physical confirmation remains open.

The entries below describe preceding checkpoints.

Runtime RM object graph (NVIDIA 0.1.58, 2026-09-12):

After IRQ installation, the actual runtime creates its own root/device/
subdevice/display objects and HPD/DP event subscriptions. Eight requests share
the original queue token and a bounded startup budget. The native notifier
admits only the current graph owner's exact request; sequencer and lockdown
messages follow that same owner while a response is outstanding.

The completed graph returns the queue to the runtime and exposes its display
object. Registered events retain change masks for later connector refresh.
Creation rejection frees the proven object prefix in reverse order; uncertain
cleanup, timeout or ACK failure retains names, receipts and GPU dependencies.
Object destruction alone does not establish DMA quiescence or restore UEFI.

One existing host run passes all 51 tests, including the actual device chain,
interleaved events and partial-failure cleanup. One module build, 51 original
ABI-field comparisons and exact legal staging pass. No new test group, guest
or hardware run. The 29 full upstream files and 18 complete source notices
are archived under ExFiles/Reference/GFX/Nvidia/0.79.10/gsp-rm-20260912.
Kernel152 and passive defaults remain unchanged. Physical firmware/IRQ/RM,
health/thermals, connector queries, full restore and native output remain open.

GSP interrupt endpoint (NVIDIA 0.1.57, 2026-09-12):

After RM discovery, the actual driver installs the returned GSP stall vector
using the existing MSI/IRQ interfaces. A valid shared INTx route is the fallback
when MSI is unavailable. The endpoint borrows the complete existing BAR0 map;
only the GSP vector and its VFN subtree are enabled. Immutable MMIO metadata
and an atomic admission gate keep the short IRQ handler independent of task
locks, queue/DMA operations, allocation and logging.

The handler acknowledges VFN/Falcon status and wakes the existing pacing task
through a semaphore with one coalesced permit. That task still submits exactly
one bounded, serialized Work slice at a time. Finite timeout polling remains
for startup, deadlines and logs. Unknown causes preserve raw diagnostics and
stop rearming. Reset waits for handler retirement, IRQ removal and owned MSI
disable; ambiguous routing or failed retirement retains the entire GPU graph.

All 51 existing host tests pass after correcting the complete-run model's BAR
size; the initial and diagnostic failures are retained in the evidence. The
real registered handler is exercised over RAM, including receipt/worker
separation, MSI/INTx and failure/close paths. Twelve original register checks,
module build and exact legal staging pass. No new test group, guest or hardware
run. Physical IRQ delivery and the semaphore wake path on OssiPC remain open.

Kernel 152 / DriverApi 35 are unchanged. OssiPC was last verified with
Kernel150/NVIDIA50 passive. Sixteen complete upstream files, thirteen source
notices and the unchanged kernel/SDK dependencies are archived under
ExFiles/Reference/GFX/Nvidia/0.79.10/gsp-irq-20260912. Firmware health, host RM
objects, full GPU/UEFI restore and native video/audio remain necessary work.

Internal RM discovery (NVIDIA 0.1.56, 2026-09-12):

After static-info acceptance, the actual runtime queries enabled GPCs, the TPC
mask of each enabled GPC, then the kernel interrupt table through the borrowed
firmware RM client/subdevice. Sparse masks keep their real IDs. The fixed flat
controls share the retained queue and native notifier; interleaved diagnostics,
lockdown and CPU-sequencer requests keep the original deadline. Each control
has at most 5 seconds within the original 30-second startup budget.

The resident inventory includes up to 128 interrupt entries and seven subtree
ranges. Unknown engines and absent vectors remain explicit; GA106 vector
bounds and the required unique GSP stall vector are checked. No partial table
is exposed before the final ACK. These queries do not register IRQs, program
VFN masks, enable engines, change clocks or release the held boot resources.

One existing host run passes 51/51 groups, including sparse high-bit masks,
actual control packets, native sequencer dispatch while waiting, RM/selector/
vector errors, failed ACK and timeout. Original C ABI comparison (18 fields),
module build and exact legal staging pass. No new test group, guest or hardware
run. Kernel 152 and the last physical Kernel150/NVIDIA50 state are unchanged.
Twenty-eight complete pinned references, full licenses and publication evidence
are in ExFiles/Reference/GFX/Nvidia/0.79.10/gsp-postinit-20260912. IRQ service,
firmware health, host RM objects, complete restore and native output remain open.

Post-init static configuration (NVIDIA 0.1.55, 2026-09-12):

After the real INIT_DONE handoff, the resident runtime sends GET_GSP_STATIC_INFO
through its native queue. Its queue0 notification has separate sender admission;
CPU-sequencer register access gains no doorbell permission. Interleaved events
and lockdown retain the request's fixed deadline. A checked, successfully ACKed
reply publishes copied firmware-owned RM handles, bounded FB regions, BAR page
directory addresses and engine capabilities. It does not release boot VRAM or
allocate/free RM objects. The default remains passive.

All 51 existing host groups pass. The added complete-run cases cover wire bytes,
notification isolation, reply lifetime, overlapping regions, failed ACK and
missing response. The first run rejected a malformed new model print packet;
its length was corrected without changing the production decoder. One C ABI
comparison verifies 63 fields; module build and exact legal staging pass. No
new group, guest or hardware run. Kernel152 is unchanged; OssiPC was last
verified with Kernel150/NVIDIA50 passive. The 28 complete pinned originals and
receipts are archived in ExFiles/Reference/GFX/Nvidia/0.79.10/gsp-static-20260912.
Real firmware acceptance, subsequent RM controls/objects, IRQ/health, thermals,
full GPU/UEFI restoration and native video/audio remain open.

Early GSP initialization messages (NVIDIA 0.1.54, 2026-09-12):

RM consumes system information and registry settings before creating its GPU
object. The start path now places those two asynchronous messages into the
actual fresh command queue before FWSEC/Booter. The same Session carries its
TX cursor/sequence through the firmware handshake; unrelated old CPU queue
state remains rejected. Preloading synchronizes payloads before cursors and
does not ring a doorbell or mark unexposed DMA as firmware-owned.

The 928-byte SystemInfo uses the held PCI identity/apertures and console size,
documented config mirror, 4-KB pages and the positive canonical end of R4OS's
48-bit CPU VA layout. It does not advertise unavailable host services. The
three pinned Nouveau boot registry settings are encoded with exact DWORD
entries. A partial preload cannot be retried; pre-submit cleanup remains valid.

One existing owner run passes 51/51 cases, including actual packets, partial
DMA failure/cleanup, preserved counters and foreign-session rejection. One C
comparison verifies 12 exact original declarations and 47 SystemInfo ABI fields;
the module build and legal staging pass. No new group, guest or hardware run.
Kernel152 is unchanged. Full source notices now occupy 41,158 bytes, preserving
the previous 27,240 bytes as an exact prefix. Twenty-six complete pinned
references and the evidence are in 0.79.10/gsp-preboot-20260912 under
ExFiles/Reference/GFX/Nvidia. Actual firmware acceptance, post-init RM, IRQ,
thermal verification and full GPU/UEFI restoration remain open.

Resident GSP runtime (NVIDIA 0.1.53, 2026-09-12):

After INIT_DONE, the actual device worker keeps its runtime Exchange alive.
Idle polls receive fresh deadlines; pending messages/sequencers retain their
original bounds. Libos print, XID and NOCAT diagnostics, current lockdown and
the native CPU sequencer are connected. Effects requiring actual RM/channel,
display, IRQ or recovery owners remain unsupported and retain their receipt.
XID logging does not itself initiate a GPU reset.

An empty runtime queue paces the dedicated Task at about 100 Hz (at least one
tick). Each Work callback retains the 64-step/2-ms bound. One raw Libos ring
is sampled per second while idle, using resident scratch space; a moving
producer is skipped. Poll/log counters are CPU observations, not a firmware
heartbeat. Runtime errors use the existing one-shot retained teardown.

All 51 existing host cases, the module build and legal staging pass. The
existing complete-run case covers post-boot deadlines, lockdown/unlock,
diagnostics, native sequencer execution/expiry, unknown/unowned messages,
raw-log DMA failure and a moving producer. No new test group or guest run;
Kernel152 and its previous SMP4 Task-to-Work evidence are unchanged. The
27,240-byte complete source notices are embedded and staged byte-identically.
Twenty-two complete pinned references accompany the source and evidence in
ExFiles/Reference/GFX/Nvidia/0.79.10/gsp-runtime-20260912.

Physical firmware start, IRQ wakeup/health, RM initialization, full GPU/UEFI
restore and native video/audio remain open. OssiPC was not contacted or
updated; its last verified state is Kernel150/NVIDIA50 passive.

Native GSP start wiring (NVIDIA 0.1.52 / Kernel 0.1.152, 2026-09-12):

Explicit `mode=gsp-start` binds the prepared original resources to the real
GA106 port: FWSEC-FRTS, GSP preparation, normal Booter Load, boot notifications
and INIT_DONE with ACK. A dedicated Task paces one outstanding normal Work
completion, bounded to 64 steps or 2 ms. DriverApi35 keeps its complete
648-byte layout and admits that Task's exact owner/epoch into normal Work;
stopped/closing Tasks and direct dedicated device access remain rejected.
Start requires a single matching adapter and already enabled bus mastering.

Startup has 30 seconds, with 5-second firmware/core phases. Errors attempt
FWSEC-SB/Booter-Unload once under a fresh 10-second bound. Before any possible
firmware effect the PRAMIN-only restore callback is permanently fenced.
All post-submit outcomes retain display and DMA memory. Full GPU/UEFI restore
is still open, so reboot after such a run requires poweroff/halt. INIT_DONE
alone does not provide native video, IRQ/runtime log/health or audio support.

All 51 existing host cases and builds pass. The existing complete-run group
drives the actual controller/port against host RAM, including bounded errors,
stale display ownership and retained cleanup; the lifecycle group checks the
registered restore callback. The existing SMP4 nvidia-runtime probe passes
in 29.36 seconds with actual Task-to-Work owner binding and close rejection.
The runner now avoids explicitly including/staging an already selected Slim
driver. No new test group or physical firmware execution. OssiPC remains on
Kernel150/NVIDIA50 passive, pending availability to power on after a required
poweroff. Evidence: ExFiles/Reference/GFX/Nvidia/0.79.10/gsp-start-20260912.

One-shot firmware teardown (NVIDIA 0.1.51, 2026-09-11):

The native port hands its retained run to a separate finite recovery budget,
preserving the original failure and partial operations. Ordinary queue and
sequencer access stays fenced; exact MMIO/DMA bindings and the actual paused
Libos reader are checked throughout. FWSEC-SB precedes normal Booter Unload
using the same run's prepared images and existing reset/upload/halt/result
executors. Errors stop without retry. WPR-down can skip Unload; the reader
stays stopped. No result frees submitted memory or restores the display.

All 51 existing cases and the module build pass. The existing complete-run
group covers success/skip, firmware faults, clocks and in-access timeouts,
changed mappings/plans, lost epochs, posted writes and denied admission.
The old truncated-aperture fixture now expects Stale before firmware access.
The teardown controller is not yet called by production DriverWork.
No new grouped case, gate, guest run or OssiPC update. Production recovery
admission, full device/console restoration and DMA quiescence remain open;
OssiPC stays on passive NVIDIA 0.1.50. Full originals and validation receipts:
0.79.10/teardown-20260911 under ExFiles/Reference/GFX/Nvidia.

Bounded GSP raw log reader (NVIDIA 0.1.50, 2026-09-11):

One reader borrows the actual run across its five Libos DMA rings. It copies
chronological raw words with 4096-byte reads, finite clocks and a final PUT
comparison. Overwritten words are explicit; changed producers discard the
sample, counter regression/DMA failures invalidate the run. Suspension keeps
the loan; cleanup cannot release the parent until the reader closes. Output
must not alias any of the seven run allocations. Raw observations do not
establish atomic firmware snapshots, decoded strings, health or quiescence.

All 51 existing cases and the module build pass; the existing complete-run
case covers rings, bounce reads, loss/wrap, deadlines, aliases, suspension
and retained cleanup. OssiPC reads all 5 initial counters (80 bytes) as zero,
completes boot-check and releases all resources. Batch 12 restores the exact
passive configuration; bootfb1920x1080 and 14 services without failure.
Native firmware boot/IRQ/log/health integration and complete recovery remain
open. Six complete originals, full MIT notices and hardware receipts are in
0.79.10/gsp-logs-20260911. The license is embedded and staged in Distribution;
standalone data payloads are unsupported by the current R4U contract.

Inactive display instance (NVIDIA 0.1.49, 2026-09-11):

STATUS_INVALID is an explicit empty snapshot only when no assigned window,
enabled cursor or memory-LUT handle depends on instance bindings. Preserve
raw controls, the real display hold/epoch and fresh comparisons. No invented
64KB backing, address0 read or extra allocation/window write. Active-instance
capture remains intact. Existing cases cover empty capture/reservation,
changed state and each contradictory dependency; all51 cases/build pass.

OssiPC now completes boot-check through all unsubmitted GSP/FWSEC/Booter,
init-memory and queue preparations, then releases every mapping/pin/CPU
buffer and display hold. Batch10 restores the exact passive configuration:
bootfb1920x1080, no pending owner,14 services without failure. This proves
CPU/DMA preparation only. Native firmware execution, complete device/display
recovery and GPU quiescence remain open, as do visible picture and audio.
Sources/evidence:0.79.10/inactive-instance-20260911. Older entries below
record prior states.

Init-abort recovery (NVIDIA 0.1.48, 2026-09-11):

Unsubmitted boot preparation now releases its display hold before init
returns an error; the kernel cannot call DriverShutdown while that hold
remains. Success, failure and shutdown share one cleanup order. OssiPC
confirms Control rejection followed by cleanup=OK, zero display hold and
zero unbind resources. Failed restoration still retains the real owners.
51 existing owner cases and the module build pass. Measured instance
control1/address0 denotes STATUS_INVALID; no dependent window/cursor/LUT
is active. Explicit support for that state and native bringup remain open.
The exact passive configuration was restored through SYSUPD batch8.

PROM lifetime (NVIDIA 0.1.47, 2026-09-11):

The verified PROM window is released before the retained CPU copy reaches
FWSEC/boot-check, allowing its shared BAR0 map. Cleanup failure retains the
window state and allocation. The existing lifecycle fixture now checks this
order, including failed unmap/collect; all 51 owner cases and the build pass.
OssiPC captures the boot image, VGA workspace and direct BAR1 mapping, then
rejects the display instance with Control. The display hold remained pending;
full boot-check and automatic recovery are still unverified. A config-only
SYSUPD restore returned the machine to passive bootfb with zero pending owner.
No GPU firmware was executed. Details and complete evidence are maintained
in the 0.79.10 prom-release-20260911 checkpoint.

GPIO4.1 compatibility (NVIDIA 0.1.46, 2026-09-11):

The measured GA106 advertises GPIO header `41 06 24 06`: 36 entries with
six bytes each. The reader accepts this form alongside the existing four-
and five-byte formats. It follows the declared stride, decodes the known
prefix and preserves the sixth byte as opaque `extension_byte` metadata.
The complete table remains bounds/overlap checked. The rejection trace now
includes its GPIO header; inspect-vbios schema 5 exposes the retained byte.
This adds no native GPIO access, display takeover or firmware execution.
The existing owner case covers all 36 records, truncated input and the
last byte; no extra test case or gate was added. Hardware evidence and
source references are recorded with the 0.79.10 integration checkpoint.

RM connector/resource topology (source preparation, 2026-09-11):

A bounded graph-owned discovery reads up to 32 RM display IDs and all four
possible connector records per ID, OR resource details and I2C port IDs.
RM displays, physical connector indices, DCB slots, current OR assignments
and communication IDs remain distinct. Dynamic displays retain their root
port; shared connectors stay shared. PRESENT=NO, unknown values, empty or
rejected fields never establish a physical socket or connected monitor.

The explicit RM dcb_index relates to the original passive VBIOS slot, never
log2(display ID). Returned VBIOS heads/SOR/CCB data remain candidates, not
active assignments. RM and VBIOS connector indices are not assumed equal.
A final Supported/DDC comparison and idle notification drain guard the
catalog; HPD invalidates it and pending responses still complete their ACK.
Errors retain exact status, and ambiguous failures retain graph ownership.

51 existing cases pass after correcting command consumption in the full
32-ID synthetic responder; one targeted original C ABI comparison and one
module build pass. NVIDIA 0.1.44 stays byte-identical. Six complete original
references/logs: ExFiles/Reference/GFX/Nvidia/0.79.12/topology-20260911;
topology_checkpoint in Docs/Drivers/GrafikFirmware07910.json. No new gate.
This historical preparation is integrated by NVIDIA 0.1.59-0.1.61 above.
Bus transport completion and physical HDMI/audio qualification remain open.

Coherent receiver refresh with shared R4GFX parser (source preparation, 2026-09-11):

The canonical RM graph now lends a bounded receiver reader its sole runtime
token. Supported/current-connect checks precede RAW EDID; a second connect
query and final idle notification drain precede capture access. Raw bytes
and the unchanged R4GFX EDID/CTA report live in caller-owned storage. The
manifest and named library module provide the shared parser; no duplicate
decoder or separate library version was introduced.

Statuses separate unsupported/disconnected, missing/rejected EDID, invalid/
unsupported data and incomplete/valid EDID. GET_EDID_V2 is limited to2048
bytes; the shared parser allows4096. Missing advertised blocks stay explicit;
larger native DDC/AUX reads remain open. No monitor-power/audio inference.
HPD or a changed final connection rejects the candidate while preserving
the outstanding request until ACK. Notifications still need real handlers.
ACK/deadline errors retain the run; failed observation/release records the
first failure. Later valid observation/cleanup uses its own finite budget.

51 existing cases and one module build pass; no new case/gate/ABI probe/guest.
NVIDIA0.1.44 is byte-identical and the library repository is unchanged.
Nine complete references/shared sources and logs: ExFiles/Reference/GFX/
Nvidia/0.79.12/receiver-20260911; receiver_checkpoint in
Docs/Drivers/GrafikFirmware07910.json. Fixtures are synthetic RFO displays.
Native bootstrap/RM, port mapping, multi-graph routing, larger reads and
platform catalog publication remain open, as do physical Hisense/HDMI/ELD/
audio acceptance. OssiPC offline and untouched.

Session RM namespace and complete graph (source preparation, 2026-09-11):

One namespace ledger now stays in the GSP Session across runtime handoffs.
The canonical graph reserves root/device/subdevice/display/HPD/DP names
before RM I/O, then owns creation, display loans and reverse cleanup through
the existing protocol owners. Bookkeeping retires only after complete graph
cleanup. Rejected allocations and unsubmitted cancellation consume IDs;
uncertain teardown retains the graph and reservation. No within-run ID reuse.
The client range follows Nouveau; object IDs avoid NVIDIA's RM/firmware
generated ranges.64 simultaneous graphs and monotonic counters are bounded;
exhaustion cannot partially consume a reservation. Live owner copies fail.
Routing between multiple live graph sinks remains higher runtime owner work.

51 existing cases and one module build pass; NVIDIA 0.1.44 remains byte-identical.
Eight complete pinned originals, source notices and logs: ExFiles/Reference/
GFX/Nvidia/0.79.12/rm-namespace-20260911. See rm_namespace_checkpoint in
Docs/Drivers/GrafikFirmware07910.json. Two declaration-shadowing names were
corrected before the passing rerun. No new grouped case/gate, ABI probe or
guest run. Native bootstrap, internal RM/display-instance initialization,
monitor refresh/recovery and physical graphics/audio remain open. OssiPC
offline and untouched. A new Session still requires a new/quiesced GPU run.

RM display event objects (source preparation for 0.79.12, 2026-09-11):

The driver now owns bounded allocation, enable, disable and free sequences
for one HPD and one DP-IRQ event on a single RM client/subdevice. The caller
reserves all names and retains the live parent graph. Confirmed creation
rejections allow reverse cleanup; a possibly enabled event is disabled first.
Failed disable/free or ambiguous transport/ACK retains objects and parents.

Exact client/event/index and receipt checks route addressed/list notices to
the sole registration. Copied change masks preserve all bits and overlap;
they require later monitor/EDID refresh. Initial notifier data is raw state.
Display-aware ordinary and CPU-sequencer completion now clears the Channel
receipt together with its Exchange ACK, preserving an outstanding query and
allowing handoff. Events cannot leave a stale semantic dispatch behind.

51 existing cases and one module build pass; NVIDIA 0.1.44 is byte-identical.
The temporary original-C comparison confirms event24, notification20 and
ALLOC32/CONTROL24/FREE16. Thirteen full pinned references, source notices,
logs and the two corrected fixture compile failures are archived under
ExFiles/Reference/GFX/Nvidia/0.79.12/event-objects-20260911.
See event_objects_checkpoint in Docs/Drivers/GrafikFirmware07910.json.
No new grouped case/gate or guest run. Productive bootstrap, global RM name
reservation, native event registration/refresh/recovery and physical display/
audio acceptance remain open. OssiPC offline and untouched.

GSP runtime notifications (source preparation for 0.79.10, 2026-09-11):

The shared runtime exchange now has typed decoding and bounded owner delivery
for twelve ordinary notification kinds. POST_EVENT preserves client/event/
index/list identity and raw status. Its C base is 32 bytes but data begins at
byte 29; RC_TRIGGERED uses the current 48-byte header and journal extent.
One host comparison against exact pinned C declarations confirms these and
the fixed line/modeset/extdev/FECS/recovery layouts. Padding is not a field.
HPD and DP IRQ data preserve all mask bits and simultaneous plug/unplug.
They represent notifications, not verified connections or current EDID.

A mandatory owner sink admits registrations/capabilities and completes one
bounded local delivery or copies deferred work before ACK. Exact receipt,
epoch and finite deadline remain bound. Before/after delivery failures and
ambiguous ACK never replay the callback. An outstanding RM request survives;
lockdown clear occurs after ACK. CPU-sequencer receipts stay on the existing
native RuntimeSequencer path, without ordinary-handler ACK. One serialized
owner is required; callbacks cannot recurse into RM or retain borrowed bytes.

51 existing cases and one module build pass; no new grouped case/gate/guest.
NVIDIA 0.1.44 remains byte-identical. Eleven complete pinned originals, full
notices, ABI comparison and logs: runtime-events-20260911 under
ExFiles/Reference/GFX/Nvidia/0.79.10. See runtime_events_checkpoint in
Docs/Drivers/GrafikFirmware07910.json. New code remains host-linked.
Actual RM event subscriptions/registration routing and native sinks, remaining
notification kinds, bootstrap/IRQ/health/recovery and physical display/audio
acceptance remain open. OssiPC is offline and has not been contacted.

GSP runtime CPU sequencer (source preparation for0.79.10, 2026-09-11):

The sequencer now handles notifications owned by the shared runtime exchange,
using the existing complete-stream admission and bounded execution. An open
RM request keeps its identity and deadline while its notification executes.
The native RuntimeSequencer borrows that exact receipt, Session, epoch and
retained BAR0/DMA run. Queue traffic is held until all effects complete; only
the matching receipt cursor can then be acknowledged. Poll/core phases and
mandatory delays cannot acquire a fresh budget when the exchange tightens it.

Failed MMIO, timeout, stale mapping or ACK stops the execution without replay.
Incomplete native metadata needs actual device quiescence before disposal;
close never acknowledges, resumes suspended logs, frees DMA or resets cores.
The existing GA106 core executor is reused, including CORE_RESUME's retained
Libos arguments and log suspension. Native runtime admission remains required.

51 existing cases and one module build pass; NVIDIA0.1.44 remains byte-identical.
New fixture type errors and the order of a terminal DMA-failure scenario were
corrected; all logs are archived. No new grouped case, gate or guest run.
Twelve complete pinned originals and evidence: runtime-sequencer-20260911 in
ExFiles/Reference/GFX/Nvidia/0.79.10; runtime_sequencer_checkpoint in
Docs/Drivers/GrafikFirmware07910.json. Native runtime remains host-linked.
Production bootstrap/dispatch, restoration/quiescence and physical display/
audio acceptance remain open. OssiPC is offline and has not been contacted.

GSP boot/runtime handoff (source preparation for0.79.10, 2026-09-11):

The native port now transfers the exact Session into runtime only after
processed/ACKed INIT_DONE, complete retention and explicit native admission.
The same BAR0/DMA/queue epoch, cursors and lockdown survive. Every queue
callback carries its finite operation deadline; runtime requests may run
after the original boot deadline without extending or replacing that limit.
Old boot callbacks cannot reset or poison the transferred runtime. A failed
or rebound runtime Session invalidates its native queue facade as well.

51 existing cases pass, including an actual host Boot -> native handoff ->
gsp_exchange request/reply after both old boot deadlines. Foreign/pending/
missing/denied/late handoffs, lockdown, epoch loss and deadline renewal are
covered. One module build proves the entire NVIDIA0.1.44 R4D unchanged.
Initial pointer-type and synthetic INIT_DONE status errors were corrected;
both successful and failed logs are archived. No new test case/gate/guest.

Eight unchanged pinned originals accompany runtime-handoff-20260911 under
ExFiles/Reference/GFX/Nvidia/0.79.10. See runtime_handoff_checkpoint in
Docs/Drivers/GrafikFirmware07910.json. Runtime executor remains host-linked;
passive main only passes its existing deadline to its two staging reads.
Real native boot/phase admission, runtime CPU-sequencer and notification
handlers, complete recovery and physical graphics/audio remain open.
OssiPC remains offline/untouched; no hardware or firmware-ready claim.

GSP queue notification (source preparation for0.79.10, 2026-09-11):

The transport now requires an explicit notification for sending. It checks
both queue and notifier epochs, admits and retains before publishing bytes,
then notifies once after the complete payload and synchronized write cursor.
Full queues and receive acknowledgements do not ring the command register.
Any ambiguous notification failure stops the Session without retry/free.

gsp_sequencer_port binds the exact run_memory lease, DriverApi and BAR0 run.
It writes zero to bare-metal RM queue0 at0x110c00, with x86 ordering and
the existing BOOT0 posted-write flush. The shorter request deadline is
checked immediately before the store. ACK writes also retain all DMA.
The native owner still supplies firmware readiness/phase and access policy;
this facade does not renew its run deadline or prove GPU quiescence.

51 existing cases and one module build pass. The first two test runs found
a wrong success constant in the new host fixture; that fixture is fixed.
Eight complete pinned originals accompany queue-notify-20260911 under
ExFiles/Reference/GFX/Nvidia/0.79.10. Full source MIT notices are retained.
See queue_notification_checkpoint in Docs/Drivers/GrafikFirmware07910.json.
The whole NVIDIA0.1.44 R4D remains byte-identical. This is host-linked source;
passive main does not open it. No new case/gate, guest or physical run.
OssiPC offline/untouched; actual bootstrap/runtime/recovery, notification
handlers and physical graphics/receiver/audio acceptance remain open.

RM object lifecycle (source preparation for0.79.12, 2026-09-11):

gsp_objects now creates the fixed client/device/subdevice/display-common
hierarchy and destroys it in reverse order, over the same gsp_exchange
owner as display queries. Each name becomes live/free only after its
validated RM response and queue ACK. The object owner can lend the runtime
to the display channel and reclaim it for destruction. Pending/failed work
cannot transfer, and an old owner cannot stop an already-transferred session.

Confirmed allocation rejection permits explicit cleanup of the live prefix.
Ambiguous sends, replies or ACKs and failed free retain the affected name
and remaining ancestors. Each create/destroy phase has one fixed deadline.
Completion releases four RM names; firmware and DMA queues remain active.
Global name reservation, actual native admission/internal RM initialization
and display-instance binding remain responsibilities of the future caller.

The570.144 client structure is120 bytes, including a zero OS PID pointer;
the older Nouveau535 excerpt is108 bytes and is not copied as the wire ABI.
Only the four selected fixed structures are encoded, with zero padding.
26 full pinned originals and six complete object-source notices accompany
rm-objects-20260911 under ExFiles/Reference/GFX/Nvidia/0.79.12. Shared exchange
retains the four original source notices of the prior display channel.

51 existing owner cases and one module build pass on the first attempt.
The entire NVIDIA0.1.44 product artifact remains byte-identical. New object
code remains host-linked preparation; no new case/gate, guest, inspector,
hardware, version, ABI or Distribution change. See rm_object_checkpoint in
Docs/Drivers/GrafikFirmware07910.json. OssiPC remains offline/untouched;
native firmware/transport/handlers, complete receiver and audio remain open.

RM display queries (source preparation for roadmap 0.79.12, 2026-09-11):

gsp_display_rpc now encodes the three fixed NV0073 supported/connected/EDID
queries and owns one outstanding control on a retained GSP Session. Boot
hands queue ownership to the runtime after acknowledged INIT_DONE; real RM
object allocation may precede the display channel's single-use claim. An
idle, acknowledged channel can return ownership for actual object cleanup.
The API neither creates nor proves the supplied live RM handles.

Responses validate object/command/size/flags and distinguish RPC from RM
errors. Notifications require their real handler before ACK. Backpressure
and lockdown preserve the deadline. Topology changes cancel unsent dependent
queries or retire in-flight/deferred results. EDID requires a preceding
positive RM connection bit and remains at most2048 raw borrowed bytes;
complete EDID/checksum/CTA and connector-generation publication still follow.

51 existing owner cases pass. The initial run passed; review of the runtime
handoff prompted one targeted rerun, also successful. One canonical module
build proves the entire NVIDIA0.1.44 artifact unchanged. New control code is
host-linked preparation only; no version bump, Distribution or ABI change.
No new case/gate, inspector, guest or physical run. Eleven full pinned
originals and four complete MIT source notices accompany rm-control-20260911
under ExFiles/Reference/GFX/Nvidia/0.79.12. See rm_display_control_checkpoint
in Docs/Drivers/GrafikFirmware07910.json. OssiPC remains offline/untouched;
native RM objects, queue/doorbell, handlers, receiver and audio remain open.

Internal GPIO wiring (NVIDIA 0.1.44, roadmap 0.79.12 preparation):

The existing VBIOS reader now snapshots optional GPIO 4.0/4.1 assignment
tables, including all 255 possible records, with exact four/five-byte
reads and disjoint ROM bounds. It matches the seven HPD function names
against the complete internal table. Missing, ambiguous, invalid input
and mapped metadata remain distinct; duplicates never choose the first
entry. Input polarity requires opposite levels with both states input.
Dedicated lock pins, reserved bits and invalid lock assignments cannot
be presented as usable HPD inputs. Raw fields and unknown legacy fields
remain available. Connector HPD masks refer to these same seven mappings.

PROM diagnostics and inspect-vbios schema 4 expose the shared catalog.
The external expander pointer remains explicitly unparsed. Six-bit pin
numbers are firmware metadata, not admission to GA106's 32 GPIO lines.
Nouveau also refuses an independent GA106 GPIO driver under GSP/RM;
no live register access, GPIO initialization, interrupt ownership or
firmware control is added. Actual connection state stays unknown.

51 existing owner cases pass after fixing two typed-array literals in
the new synthetic fixture. The module and existing inspector also pass;
no added case/gate, guest or hardware run. The inspector checks seven
synthetic pins with both polarities and connector A/G versus B masks.
Fourteen full pinned originals accompany gpio-20260911 under
ExFiles/Reference/GFX/Nvidia/0.79.12. The existing connector notice grows
to 5105 bytes with both complete GPIO source notices; its prior
2620 bytes are an exact prefix, and the other 29 resources are unchanged.
Current evidence: gpio_topology_checkpoint in
Docs/Drivers/GrafikFirmware07910.json. OssiPC remains offline/untouched;
native firmware/recovery, external GPIO and real receiver acceptance open.

Previous physical connector wiring (NVIDIA 0.1.43):

The existing VBIOS reader now retains bounded physical connector and CCB
catalogs. DP/TMDS alternatives share original path masks instead of implying
another socket. Catalogs preserve candidate heads/SORs, logical exclusion
buses, pad references, HPD function masks and maximum DDC speed metadata.
Short records keep unavailable extended fields null; absent references
stay absent. A path referencing a skipped connector is rejected.
The same data appears in passive PROM diagnostics and inspect-vbios schema 3.
These are wiring declarations, not live HPD, active routing or EDID data.

Source research confirms GA106's gm200_i2c constructor refuses a separate
I2C driver when GSP/RM is active. The pinned RM GET_EDID_V2 control is the
planned firmware route for TMDS; its 2048-byte limit, connected single-ID
requirement and raw/no-cache flags remain explicit. No bus transaction,
new MMIO access, firmware call or common output publication was added.
51 existing owner cases pass after correcting an initial Zig table-type
compile error; the final module build and the existing synthetic VBIOS inspector
pass. No added case/gate or guest/hardware run. Eleven full pinned sources
and complete MIT notices accompany connectors-20260911 under
ExFiles/Reference/GFX/Nvidia/0.79.12. Previous 29 resources are identical;
one 2620-byte notice resource and its Distribution copy were added.
Current evidence: connector_topology_checkpoint in
Docs/Drivers/GrafikFirmware07910.json. OssiPC remains offline/untouched;
native firmware, recovery and complete real receiver acceptance stay open.

Previous boot-check completion cleanup (NVIDIA 0.1.42):

Normal boot-check completion omitted the display-context close, leaving
context_owner held and making final boot_vram.close fail. Normal completion
and shutdown now share the same context/payload-before-BAR1 cleanup helper,
followed by parent boot-hold release. Failure stops the chain for retry.
The existing lifecycle case calls this exact driver helper with held
owners: active VRAM borrow and failed payload unmap retain all three BOs;
retry succeeds and is idempotent. Both actual call sites are inspected.
51 existing cases and one module build pass first invocation; 29 resources
unchanged. This validates cleanup, not the full firmware boot-check entry
or a physical GPU. No new case/gate/guest/hardware run. Evidence:
display_cleanup_checkpoint in Docs/Drivers/GrafikFirmware07910.json;
ExFiles/Reference/GFX/Nvidia/0.79.10/display-cleanup-20260911.
OssiPC remains offline/untouched; native recovery/bringup remains open.

Previous fresh BAR1 mapping admission (NVIDIA 0.1.41):

Before the first-boot VRAM lease publishes any borrow, the mapping owner
now compares the current BAR1 control and every complete saved dependency
page with its immutable snapshot. It checks control before and after those
reads, closes the shared PRAMIN reader and freshly observes the parent.
Previously this admission checked saved ownership and collisions only.
A later table or block/bind mutation could therefore escape that check.

BootMappingChanged refuses admission and preserves the table BO; failed
window restoration retains the exact child and parent owners. Direct BAR1
mode checks control even without table pages. The existing 128-page bound,
five-second deadline, epoch, shared register mapping and read-only BO remain
in force. No new registers, table writes, binding/cache changes or native
execution authority are introduced.

The existing lifecycle case changes an unused final dependency-page byte
and the block control after capture; both fail without publishing a borrow.
Restoring originals allows the normal success/cleanup sequence. All 51
cases and one module build pass first invocation; no new case/gate/guest.
All 29 resources match NVIDIA40 exactly. Evidence: mapping_refresh_checkpoint
in Docs/Drivers/GrafikFirmware07910.json and
ExFiles/Reference/GFX/Nvidia/0.79.10/mapping-refresh-20260911.
OssiPC remains offline/untouched; native recovery and hardware acceptance
are still open.

Previous complete active VRAM image backing (NVIDIA 0.1.40):

The existing immutable payload BO now also contains all resolved active
ISO image planes and eyes, including pitch/block-linear backing rows.
A sorted interval union merges aliases, overlaps and adjacent ranges, so
the same physical bytes are copied once. Each image and cursor/LUT binding
retains its own offset into that union. Address/count/byte limits are checked
before changing the plan; failed additions leave the original plan intact.
The bound is 88 input bindings and 256 MB of unique backing.

Capture and fresh VRAM admission compare every image and asset byte, plus
the complete instance and parent scanout. Whole-payload and asset-specific
SHA256 hashes are reported. Existing 4-KB/1-MB PRAMIN chunk limits, held
epoch, five-second read deadline, read-only BO sealing and downstream
DMA/FWSEC/unmap retention remain in force. Native throughput is unmeasured.

The existing lifecycle case captures six unique ranges / 4978808 bytes:
two image surfaces and four cursor/LUT attachments. It checks all image
bytes, the concatenated payload hash, changed final padded image byte and
the prior asset, collision and lifetime failures. Union checks cover
unordered overlap/aliases, adjacency, gaps, overflow, full-capacity merge
and rejected budget changes. All 51 cases and one module build pass on
their first invocation; no added case/gate/guest/hardware run. All 29
resources match NVIDIA39 exactly. The new interval/BO code is original
R4OS Apache-2.0; prior source licenses remain unchanged. Evidence:
display_images_checkpoint in Docs/Drivers/GrafikFirmware07910.json;
ExFiles/Reference/GFX/Nvidia/0.79.10/display-images-20260911.

Native restoration is still incomplete. System-memory targets remain
explicitly unsupported; indexed LUT/scaler tables and full UEFI/device
recovery are still required. No extra compression/device state is inferred
from raw backing bytes. OssiPC remains offline and untouched.

Previous VRAM cursor and color-table payloads (NVIDIA 0.1.39):

The held display instance now resolves cursor, output/input LUT and tone-map
attachments using their exact client, handle and channel. Active mono/stereo
cursor eyes and nonzero LUT handles select the required data; stale unused
bindings are ignored. Packed cursor rows and complete eight-byte LUT entry
counts define bounded extents, with offsets widened before conversion.

Local-VRAM payloads are copied, fully compared and hashed in a private BO,
then mapped read-only under the existing held display owner. Reads stop at
both 4-KB chunks and the 1-MB PRAMIN aperture edge. Instance bindings are
compared around payload capture. Before the VRAM lease, every payload must
still match and avoid the full GSP reservation. DMA/FWSEC borrowers and
failed unmaps keep both context and payload BOs alive. Maximum 40 attachments
and 4587328 payload bytes; the existing model captures four / 30840 bytes.

All 51 existing owner cases pass after correcting the duplicate-RAMHT test
fixture to restore its original adjacent entry, now used by the cursor.
The initial 50/51 result is retained. One subsequent owner run and one
module build pass; no new case/gate/guest/hardware run. All 29 resources
verified, earlier 28 unchanged. Eight complete MIT source notices in the
new 10098-byte asset license; 38 complete pinned reference files. Evidence:
display_assets_checkpoint in Docs/Drivers/GrafikFirmware07910.json and
ExFiles/Reference/GFX/Nvidia/0.79.10/display-assets-20260911.

System-memory targets remain distinct GPU addresses. NVKMS can place LUTs
there; capture explicitly rejects AssetSystemMemory before any asset read
or allocation. No guessed CPU pointer, bus-master or cache change is used.
System reads, indexed LUT/scaler tables, extra ISO pixels and native UEFI/
device recovery remain open. Saved payloads do not yet provide native
restoration. OssiPC is offline and untouched; no new visible/audio evidence.

Previous armed color and cursor state (NVIDIA 0.1.38):

The held snapshot now retains 53 additional C67D words per fused head and
79 C67E color words per window: background, clamp, procamp/dither/scaling,
input/output color matrices, LUT and tone-map controls/bindings, plus cursor
format, size, hotspot, composition and both context/offset pairs. The core
client and both C67A cursor positions are captured too. Coordinates follow
the original C6 HAL's signed 16-bit convention. These are armed mirrors;
cursor UPDATE/FREE and submission ports are not used.

Raw color/coordinate payloads may legitimately contain all-one bits or
patterns resembling generic MMIO error sentinels. Explicit color reads
preserve these values; identity/topology, mapping/owner/epoch, one-second
deadline and two whole matching observations remain mandatory. Maximum
2896 reads; the sparse two-head/two-window fixture uses 748. Admission and
existing aperture/pixel recovery compare the color/cursor state as well.

The existing lifecycle case covers full-width payloads, enabled/disabled
cursor state, both signed eye positions and bindings, LUT metadata, a CSC
change between passes and retained recovery after cursor movement. All 51
owner cases and the module pass first invocation; no new case/gate/guest.
Final source review removed three trailing spaces in license-comment blank
lines and rebuilt the module; no repeated owner tests.
All 28 resources verified, previous 27 unchanged. Six complete source
notices are in the new 7664-byte color license. 31 full pinned originals:
display-color-20260911; current evidence is display_color_checkpoint in
Docs/Drivers/GrafikFirmware07910.json.

External LUT/cursor payloads still need resolution and backup. Indexed
CSC LUTs and output-scaler coefficient arrays cannot be recovered from
their last-write method words; diagnostics explicitly disclose this gap.
Native UEFI/device recovery, firmware start, scanout and HDMI remain open.
OssiPC is offline and untouched; no new physical or visual acceptance.

Previous display instance and used surface contexts (NVIDIA 0.1.37):

The explicit boot-check now backs up all 64KB of display instance memory
through the existing shared BAR0/PRAMIN reader, compares every page twice,
and retains a read-only BO under the exact held display owner and epoch.
MEM0/MEM1, each window client, stereo mode and both source points join the
two complete register observations: at most 748 reads in one second.

The bounded RAMHT lookup matches client, handle and channel, using the
original RM hash. Exactly 20 descriptor bytes establish target, physical
base/limit and pitch or block-linear layout. Present mode and all 27 C67E
formats select used planes/eyes; old nonzero unused handles are ignored.
RGB/YUV storage widths, pitch, decimation, source geometry and GOB row
alignment determine full spans, checked against context and VRAM bounds.
The instance and used spans must avoid every GSP reservation target.
Another complete instance comparison precedes publishing the VRAM lease,
which holds the context backup throughout its existing DMA/FWSEC lifetime.

51 existing owner cases and the module build pass on the first invocation.
Existing lifecycle/DMA groups cover actual capture, wrong/duplicate keys,
pitch/block-linear/YUV extents, collisions, changed unused instance bytes,
retention and cleanup. No new case/gate/guest run. All 27 resources verified;
previous 26 unchanged. The new full MIT context notice is 14984 bytes.
28 complete pinned originals: display-context-20260911. Current evidence:
display_context_checkpoint in Docs/Drivers/GrafikFirmware07910.json.

This saves context bytes and protects used image ranges; additional image
pixels, remaining color/cursor state and full native display/device recovery
still need work. Firmware start, native modesetting and HDMI remain open.
OssiPC is offline and untouched; no physical acceptance for this change.

Previous boot window and plane metadata (NVIDIA 0.1.36):

The held display snapshot now includes every fused window within a bounded
eight-slot profile: five core and 25 window words, including all six ISO
context handles/offsets for three planes and two eyes. It retains surface,
source/input/output geometry, format/storage/pitch and composition fields.
Thirty method addresses match explicit original tables. The same epoch,
one-second deadline and two complete observations now cover at most 692 reads.
Fresh admission and existing aperture/pixel recovery compare windows too.

Window owners are head indices or NONE; invalid/missing heads and excess
topology refuse. Offsets are context-relative 256-byte units. Ampere removed
SET_STORAGE.MEMORY_LAYOUT, so encoded pitch may mean blocks or 64-byte units.
Diagnostics explicitly leave layout/backing unresolved until ISO context
descriptors are decoded. No physical address or linear surface is inferred.

51 existing cases and module build pass. The lifecycle case covers sparse
windows 0/7, all six bindings, invalid/NONE owners, bounded topology, a change
between full passes and retained recovery after a binding change. One local
diagnostic name collision was fixed; no new case/gate/guest run. All 26
resources verified, previous 25 unchanged; full display notices extended.
Fifteen complete originals: boot-planes-20260911. Current evidence:
boot_planes_checkpoint in Docs/Drivers/GrafikFirmware07910.json.

Physical surface/context resolution, color/cursor preservation, native
recovery/modesetting and firmware start remain open. OssiPC offline/untouched.

Previous boot display state capture (NVIDIA 0.1.35):

The explicit boot-check captures the armed head/SOR state before its first
PRAMIN window write. It borrows the existing full BAR0 map, reads only fused
slots, and requires two identical complete observations under the held boot
epoch and a one-second deadline. At most 208 register reads; no display write.
The snapshot preserves ten head fields, HDMI control and SOR routing.
Valid progressive timing includes the exact 1000/1001 clock adjustment.
TMDS, DisplayPort and the C67D HDMI-FRL protocol are distinguished; unknown
timings remain raw. Armed state does not prove a visible image or sink support.

Fresh admission and the existing aperture/pixel recovery require this same
state. A change retains the common display and its resources. Native recovery
is still missing: original NVIDIA legacy save/restore skips UEFI; NVKMS uses
its native display core channel to restore an imported console surface.
GSP reset, FWSEC-SB and BooterUnload alone cannot restore UEFI scanout.
This supplies groundwork for .13 task 1 and .10 task 6, both still open.

All 51 existing cases and the module build pass. The existing lifecycle case
covers two heads/routes, rational timing, invalid state, held recovery and a
clock rollback before the first read. Review tightened that clock guard;
one test-local naming collision was corrected. No added case/gate/guest run.
All 26 resources verified, previous 25 payloads unchanged. Ten complete
pinned originals and full MIT notices: boot-scanout-20260911. Evidence:
boot_scanout_checkpoint in Docs/Drivers/GrafikFirmware07910.json.
OssiPC is offline and untouched; native firmware, scanout and HDMI remain open.

Previous boot mapping preservation (NVIDIA 0.1.34):

The explicit boot-check now resolves the entire held boot surface through
actual shared BAR0/PRAMIN access. The physical GA106 register addresses are
0xb80f40 and 0xb80f50: the pinned TU102 HAL adds 0xb80000 to VREG offsets.
The reader selects one aperture at a time and publishes at most 4 KB only
after exact window restoration, identity, epoch and deadline checks. A
failed selection retains the BAR0 child lease until bounded recovery succeeds.

boot_mapping merges contiguous VRAM ranges and backs up every full dependency
page, including the BAR1 instance. Entries must match the copied page; all
pages and control words are reread before sealing the private CPU backup.
Limits: 64 MB surface, 1024 ranges, 128 pages / 512 KB backup, five seconds.
Physical BAR1 mode needs no table allocation. The GSP VRAM lease requires the
retained mapping and rejects surface/table overlaps with its reserved targets.
The lease holds this backup through FRTS preparation and unsubmitted cleanup.

All 51 existing cases and the module build pass. The existing lifecycle case
uses sparse host VRAM behind the actual SDK/volatile reader, with timeout,
unknown-window recovery, full-page digest, collision and owner-lifetime checks.
No added cases/gates or guest run. All 25 nonallocated resources are verified;
complete additional MIT notices accompany the driver and Distribution.
Nineteen complete pinned originals: bar1-reader-20260911. Evidence:
bar1_reader_checkpoint in Docs/Drivers/GrafikFirmware07910.json.

Full device/VGA/VRAM/scanout recovery, native firmware admission, INIT_DONE
and HDMI remain open. The current callback restores only PRAMIN and pixels.
OssiPC is offline and unchanged; no hardware acceptance is inferred here.

Earlier shared BAR0 implementation (NVIDIA 0.1.33):

The opt-in boot-check now keeps one full measured GA106 BAR0 UC mapping.
Boot/VGA capture, repeated preflight and Booter fuse reads borrow this owner;
the native port can use the same mapping through openShared. This resolves
the live-window overlap rejected by the Kernel. Eight bounded leases bind
the exact API/device/resource/window, stable addresses and monotonic serials.
Each consumer keeps its existing register policy; mapping grants no execution.

Any external borrower prevents capture close or reobservation. Native effects
retain the port's borrow until its native owner proves quiescence. Child close
never unmaps the parent; partial map, unmap and collect failures retain cleanup
state. Capture keeps its own borrow through the existing PRAMIN restoration.
That recovery still covers only the aperture, not firmware or scanout changes.

All51 existing owner cases passed on the first targeted run, followed by the
module build. The two existing lifecycle/MMIO groups cover shared capture,
native identity and fuse reads with exactly one mapping, overlapping-range
rejection, stale ownership, bounded views and failed cleanup. No new case count
or gate. NVIDIA0.1.33 keeps the same385024 resident bytes and24 unchanged
firmware/legal resource payloads. Original R4OS code; Kernel remains150.

Native GPU execution remains unlinked. Full recovery, same-run firmware
admission and physical INIT_DONE/scanout/HDMI remain open. OssiPC is offline
and untouched. Evidence: shared_bar0_checkpoint; archive shared-bar0-20260911.

Previous host checkpoint: normal cold GSP core preparation and completion:

After checked FRTS, the cold prepare stage resets directly into RISC-V,
programs BCR0x111 and passes the bound Libos DMA page low32/high32. After
separate normal Booter Load, cold finish programs the boot appVersion and
observes RISC-V ACTIVE. It does not run the resume opcode, start SEC2 implicitly
or establish INIT_DONE. Native admission must bind those actual same-run
dependencies and full recovery; missing capability refuses before effects.
Stage/run deadlines include admission, and all callbacks remain exclusive
with firmware/sequencer execution. Errors retain raw state and DMA/MMIO.

Final 51 existing owner cases and module build pass. The existing core group
checks exact cold phases, DMA limits, posted failures and native MMIO ordering,
including seven native refusal/late-failure scenarios. Initial test-counter
expectation corrected; failure-only stage markers retained. Code review added
the deadline check after delayed admission and verified it in the same group.
No new case count/gate/guest. All native execution remains unlinked: NVIDIA
0.1.32 and its 24 resources are byte-identical. Six complete pinned sources/
notices are archived; complete additional notices must be packaged before linkage.

Source review found the next integration dependency: boot/VGA capture holds
partial BAR0 windows while the native port requests the whole BAR0. Kernel
MMIO ownership rejects those overlaps; both need a shared mapping owner.
Full GPU/scanout recovery and physical execution/INIT_DONE remain open.
OssiPC is offline and untouched. Evidence: `cold_core_checkpoint`; archive
`cold-core-20260911`.

Earlier linked checkpoint: retain both FWSEC images before boot (NVIDIA 0.1.32):

The opt-in boot-check keeps its original immutable SB CPU/DMA image for normal
teardown and prepares FRTS in a separate resident owner. The complete run now
requires seven distinct CPU allocations and both synchronized FWSEC mappings.
FRTS must name the exact live reservation belonging to this boot backing; SB
must be a separate complete command 0x19 image. Wrong roles, missing storage,
other APIs/backing, duplicate pins and CPU/DMA overlaps refuse before queue
ownership. Both images remain held through execution failure. The init plan
excludes both mappings; its bounded capacity is 261 spans. Unsubmitted cleanup
closes FRTS and SB before releasing the boot reservation and snapshots.

All 51 existing owner cases and the module build pass. The existing lifecycle
case compares actual simultaneous SB/FRTS CPU/DMA bytes across ten scenarios;
every FRTS preparation/cleanup failure preserves SB. The run-lease case checks
paired ownership, live metadata, aliasing, role/pin changes and retained close.
An initial first-boot fixture state/cleanup error was corrected; log retained.
No new gate, case count or guest run. NVIDIA 0.1.32 has 385024 resident bytes and 3567
relocations; all 24 pinned resource payloads remain unchanged. New binding is
original R4OS code; three complete reference originals/notices are archived.

OssiPC is offline and untouched; last physical evidence is Kernel150/NVIDIA28
passive. No firmware is executed. Full native GPU/scanout recovery, GSP startup
and HDMI remain open. Ordinary passive mode still prepares only SB. Evidence:
`fwsec_pair_checkpoint`; archive `fwsec-pair-20260911`.

Earlier normal Booter completion and log-reader lifetime (host qualified):

The native executor now distinguishes normal cold Load and Unload. It checks
the complete metadata DMA page and exact mailbox arguments before effects,
uses SEC2 and suspends the real log reader before reset. Unload is skipped
without reset or log changes when the observed WPR2 address field is zero.
After HS halt, mailbox0 must be zero; normal unload must also clear WPR2.
Raw mailboxes/WPR remain available on failure. Log reading resumes only after
the checked result. Failed operations cannot replay or release retained DMA.
Every added step shares the original clock/epoch. Suspend/resume and GC6
need separate state; this profile does not silently select those modes.

Final 51 existing owner cases and module build pass. Existing Falcon and
actual SDK/MMIO cases exercise commands, skipped unload, log coordination
and failures; the SEC2 model also handles absent RESET_READY with an advancing
clock. No new case count, gate or guest run. Six complete pinned originals
and licenses archived. Native execution remains unlinked, so NVIDIA0.1.31 and
its 24 resources are byte-identical. Package complete additional execution
notices before linkage. OssiPC is offline and untouched; full GPU recovery,
physical execution/authentication, GSP startup and HDMI remain open.
Evidence: `booter_result_checkpoint`; archive `booter-result-20260911`.

Earlier FWSEC completion checks after the actual Falcon run (host qualified):

The prepared native executor can now check command-specific FWSEC results
after its own reset, measured TCM, upload/start/halt sequence. FRTS checks the
scratch error, initialized WPR2 and exact low target address. SB checks read
protection, GFW completion and its scratch error. Each step reads one register
under the original epoch/deadline and MMIO policy; failures preserve raw data
and cannot replay. Unrelated scratch bits are preserved. Result success does
not release DMA/MMIO or establish GSP readiness or global GPU quiescence.

The existing Falcon and SDK/MMIO groups cover both commands and their failure
conditions; final 51-case owner run and module build pass. No new case/gate or
guest run. Six complete pinned NVIDIA files/notices accompany the reference
archive. Native execution and result checks remain unlinked; NVIDIA0.1.31 and
its 24 resources are byte-identical. Package all additional execution notices
before linkage. OssiPC is offline and untouched; actual firmware execution,
full GPU recovery, Booter results and HDMI remain open.
Evidence: `fwsec_result_checkpoint`; archive `fwsec-result-20260911`.

Earlier linked FWSEC-FRTS preparation bound to retained VRAM (NVIDIA 0.1.31):

The opt-in boot-check now closes its earlier SB CPU/DMA image and prepares
a fresh immutable FRTS image from the retained VBIOS. Command 0x15 names the
exact reserved 1-MB FRTS region through the unchanged 48-byte encoder. The
real DMA API stages all prepared bytes, including supported bounce copies.
The full display epoch, reservation serial, stable consumer address, API
identity and live target/metadata are checked before execution-lease admission.

The exclusive target borrow survives partial allocation and cleanup failures.
DMA unmap, unpin and CPU free precede target release; the parent VRAM lease
and snapshots stay held until then. A late target-release failure cannot free
the CPU image twice. Active execution owners prevent premature close.

All 51 existing owner cases and the module build pass. The existing lifecycle
case now checks actual FRTS CPU/DMA bytes, ten preparation/cleanup scenarios,
wrong/moved/duplicate owners and retained release. The first test compilation
needed a fixture variable rename; its log is preserved. No new case count,
gate or guest run. R4D: 380,928 resident bytes, 3,589 relocations, 24 unchanged
pinned nonresident resources. No additional external implementation is linked.

OssiPC is offline and untouched; last physical evidence is Kernel150/NVIDIA28
passive. This prepares FRTS without executing it. Full GPU/scanout recovery,
firmware startup and HDMI remain open. Evidence: `fwsec_frts_checkpoint` in
`Docs/Drivers/GrafikFirmware07910.json`; archive `fwsec-frts-20260911`.

Earlier boot VRAM reservation and snapshot lifetime (NVIDIA 0.1.30):

The existing boot-check now keeps its boot/VGA snapshots throughout firmware
resource, DMA and queue preparation. A resident exclusive reservation binds
seven exact target regions to a fresh first-boot layout and the actual staged
WPR metadata. Changed framebuffer size, targets or metadata refuse admission.
Full display epochs and nonwrapping reservation serials reject old bindings,
including reuse of the same reservation during the same display hold.

The fresh preflight borrows the existing VGA register window, avoiding an
overlapping MMIO alias. Closing the capture or boot storage while borrowed
fails. Cleanup first releases the unsubmitted DMA execution owner, then the
VRAM reservation and storage, finally the CPU aperture and display snapshot.
General VRAM allocation remains withheld: the old scanout GPU mapping and
full recovery after firmware effects have not yet been implemented.

51 existing owner cases pass in one targeted run, as does the module build.
The existing lifecycle case checks the actual capture/reservation owners;
the existing storage case checks real encoded/synchronized metadata. No new
case count, gate or guest run. All 24 nonresident R4D resources remain pinned;
the module has 380,928 resident bytes and 3,511 relocations.

Default mode remains passive. OssiPC is offline per the user; NVIDIA 30 has
not been installed or physically tested. Firmware execution, native scanout
and HDMI audio remain open. Evidence: `vram_reservation_checkpoint` in
`Docs/Drivers/GrafikFirmware07910.json`; archive `vram-reservation-20260911`.

Earlier current VGA workspace preservation (NVIDIA 0.1.29):

The existing opt-in boot-check now retains both the boot framebuffer and the
current GA106 VGA workspace in real private BOs. Under the common display
hold it rechecks the engine state, saves BAR0_WINDOW, copies through PRAMIN
in bounded 4 KB steps and verifies restoration of the original window.
The only permitted register writes select/restore that CPU aperture. The
planned GSP relocation target is not confused with the current VGA base.

Partial writes, expired capture deadlines and failed cleanup retain the same
owner until verified recovery. A changed VGA base or unknown window refuses
release. This aperture-only callback cannot recover executed GPU firmware,
DMA or native scanout. Firmware execution and VGA relocation remain disabled;
the normal passive mode is unchanged.

51 existing owner cases and the module build pass. The existing SDK lifecycle
case exercises the actual snapshot owner, two BOs, MMIO and retained recovery
against a host register model. No new case count, gate or guest run. The module
has 24 nonresident resources; full notices from five pinned MIT sources are
included in the R4D and all 14 required Distribution legal files stage cleanly.

OssiPC is temporarily offline per the user. NVIDIA 29 has not been installed
or tested on it. Its last verified state remains Kernel 150 / NVIDIA 28 in
passive mode; physical VGA capture/restore and image/audio acceptance are open.
Evidence: `boot_vram_checkpoint` in `Docs/Drivers/GrafikFirmware07910.json`;
archive `ExFiles/Reference/GFX/Nvidia/0.79.10/boot-vram-20260911`.

Earlier boot-display preservation (NVIDIA 0.1.28 / Kernel 0.1.150):

The common display owner can now freeze normal and firmware CPU writers
before output/queue discovery. It copies every boot framebuffer row, including
pitch padding, into a real resident byte BO and keeps a separate reference
and immutable read lease. The old display API's 40-byte prefix is preserved;
two optional size-gated slots extend it to 56 bytes. Older providers remain
usable. Short request headers are rejected before reading the full payload.

Before the first possible device effect the owner must latch retention.
Afterwards only actual driver-confirmed DMA quiescence and restoration of the
original scanout mapping permit pixel restoration and release. Failed cleanup
or recovery keeps the driver, snapshot and writer gate. Confirmed hardware
recovery is not replayed merely because a later resource release failed.
The hold publishes a real pending owner and no native device capabilities.

The existing NVIDIA boot-check captures/hashes/releases this snapshot before
its unsubmitted firmware preparation. OssiPC preserved 2,457,600 bytes at
800x600, pitch 4096, boot generation 1 / hold generation 2, then released all
snapshot references. Kernel 150 / NVIDIA 28 were installed through SYSUPD and the
exact passive configuration restored. No GPU firmware or display register
programming, actual GPU recovery, new visible-image or audio acceptance.

48 existing display cases, 11 SDK cases plus C, Contract checks and the existing
SMP4 EXAMPLE gfx-memory fixture pass. The guest uses actual BOs, checks the old
query canary, immutable writes, stale holds and early producer release. No new
test case count, recurring gate or guest profile. Native VRAM/VGA ownership,
firmware-run binding and real GPU recovery remain open. The executable Falcon
paths are still unlinked. Current evidence: `boot_display_checkpoint` in
`Docs/Drivers/GrafikFirmware07910.json`, archive `boot-display-20260911`.

Earlier complete GA106 reset-to-firmware run (host qualified):

`falcon_run` owns engine reset, fresh TCM observations and the HS upload as
one bounded operation. The shared core implementation now selects SEC2's
actual reset registers as well as GSP's. After reset, the executor reads
HWCFG twice, checks scrub/reset/core state and validates the complete image
against the measured IMEM/DMEM capacities. Caller-supplied capacity numbers
and an external reset-success callback are no longer part of this entry.
The original BCR behavior is preserved: VALID is checked after an actual
core switch; an already-selected Falcon does not require a new switch.

`Port.beginFirmware/stepFirmware` replace the earlier direct-HS binding.
Pure admission must hold exact firmware/DMA and VRAM/VGA/display recovery
before the first reset write. The second-page BCR aperture is checked up
front. The same retained MMIO owner, epoch/deadline and failure state cover
reset, observation and upload. Failed or moved operations cannot restart;
raw mailboxes and Falcon halt remain distinct from firmware authentication
and whole-device quiescence.

The existing 51 owner cases pass, with the HS and SDK/MMIO cases extended;
no additional test file, gate or guest variant. The original C comparison
now covers 39 core values (nine added SEC2/TCM values) and 34 HS values.
210 complete NVIDIA originals plus the MIT Nouveau capacity source at Linux
commit 038d61fd642278bab63ee8ef722c50d10ab01e8f are archived in
`falcon-run-20260911`. The module is still byte-identical to NVIDIA0.1.27;
these executable paths remain unlinked. No hardware run/update occurred.
Native VRAM/VGA/recovery ownership, FRTS/initial boot, result interpretation,
IRQ/log/health service and demonstrated quiescence remain open. Additional
full MIT notices must be packaged before executable linkage. Current evidence:
`falcon_run_checkpoint` in `Docs/Drivers/GrafikFirmware07910.json`.

Earlier GA106 HS Falcon loader and MMIO binding (host qualified):

`falcon_hs` implements the original GA102 HS upload/PKC/start/halt sequence
for GSP FWSEC and SEC2 Booters. It waits for DMA queue space before changing
bases and before each 256-byte transfer, then for IDLE after each complete
IMEM/DMEM transfer. It programs RSA3K BROM parameters, the boot vector and
optional mailboxes, selects the correct CPU start alias and returns raw
mailboxes after halt. Halt alone proves neither authentication nor quiescence.

One bounded phase per step shares a finite deadline and live epoch. Errors,
attempted writes and last register values remain available; failed operations
cannot replay. The native MMIO port retains DMA before effects, orders posted
writes through BOOT0 and excludes sequencer access while HS is active. It
rejects a short SEC2 second-register-page aperture before starting DMA. A
required owner callback must bind the exact retained firmware, completed
reset/Falcon selection, actual TCM limits and VRAM/VGA/display recovery.

51 cases in the existing owner step pass, including one grouped HS case and
the extended actual SDK/MMIO accessor case on host memory. 34 HS register
values match the complete original NVIDIA C headers. The full 3,156-file
source pin was verified; 210 complete originals/notices are archived under
`falcon-hs-20260911`. No new gate or guest run. The module rebuild is byte
identical to NVIDIA 0.1.27: these routines remain unlinked from `main.zig`.
No update or hardware execution in this checkpoint. Native reset/TCM and
recovery ownership, initial FRTS/Booter execution, result interpretation,
IRQ/log/health service and proven post-submission quiescence remain open.
Before executable linkage, extend the packaged full MIT notice bundle.
Evidence: `falcon_hs_checkpoint` in `Docs/Drivers/GrafikFirmware07910.json`.

Earlier production GA102 Booter Load/Unload preparation (NVIDIA 0.1.27):

The loaded R4D now provides fourteen original production parts for both
Booters, pinned to NVIDIA 570.144, with a separate 24,640-byte full notice
bundle. The existing offline provisioner accepts `-Component booter`; it
reuses the original decoder export. No driver download or version fallback.

`booter` validates each hash, the nine-word HS header, two 384-byte signatures
and patch metadata before changing a private image. Its SEC2 ucode3 fuse is
measured independently of FWSEC ucode9. Separate output and exact in-place
preparation are allowed; partial or signature/metadata aliases are rejected. Actual DMA
addresses form separate IMEM/DMEM plans. `booter_storage.Pair` admits the same
loaded-module generation, applies one bounded deadline and retains partial
heap/pin/map failures through cached teardown callbacks.

Both images join the complete run lease: six CPU allocations and up to
fifteen DMA mappings. OssiPC confirms fuse version 1, signature index
0, both prepared images (60,416/40,192 bytes), fifteen mappings,
both queue headers and complete ordered cleanup. Two update boots install
NVIDIA 0.1.27 and restore the exact passive configuration. Bootfb remains
800x600/generation 1/reset 0/owner 0. GPU authentication/execution and a new
visible-picture or audio acceptance are not claimed.

50 cases in the existing owner step and the module build pass. Two grouped
cases cover signature admission and the actual production resource/SDK
storage path, including second-image failures and retained cleanup. The
existing complete-run case now covers both Booters. No new gate or QEMU run.
The R4D contains 23 file resources and 356,352 resident bytes. Core/sequencer
execution is still unlinked. Native VRAM/VGA/display recovery, FRTS startup,
SEC2 TCM admission, firmware start/IRQ/log service, health and demonstrated
quiescence after submission remain open. Nine complete original sources and
notices accompany `gsp-booter-20260911`; 0.79.10 remains open.

Earlier complete GSP run-memory lease (NVIDIA 0.1.26):

`gsp_run_memory.Lease` holds all four CPU allocations and up to thirteen
GSP/boot/init/FWSEC DMA mappings under one exclusive, stable owner. It checks
completed stagers, actual DriverApi identity, unique handles and disjoint
CPU/DMA ranges before borrowing the kernel-validated queue lease. Every nested
close path refuses teardown before changing reports or releasing resources.
The queue port revalidates the whole run; errors invalidate further I/O.
Before any future GPU effect the run must latch retention. Only an unsubmitted
matching run may release; timeout, INIT_DONE or Falcon halt cannot free DMA.

Boot inputs now retain the mapped FWSEC plan, actual Libos DMA address and
the admitted descriptor appVersion. The existing boot-check uses this lease.
OssiPC/Kernel 0.1.149 confirms four allocations, thirteen mappings, both
32-byte headers and complete ordered cleanup. NVIDIA 0.1.26 remains installed;
the exact original passive configuration was restored after two update boots.
Bootfb remains 800x600, generation 1/reset 0/owner 0. No GPU command or firmware
start occurred; the user was unavailable for a new picture/sound acceptance.

48 cases in the existing owner step and the module build pass. One grouped
case covers ownership faults through actual init Storage/SDK callbacks plus
admitted descriptor fixtures; it does not execute GPU hardware. No new gate
or QEMU run. The module has 286720 resident bytes and eight unchanged file
resources. Core/sequence execution remains unlinked; only the Resume value
type is reused. The staged FWSEC command is still 0x19 (SB); it is not the
FRTS startup command. Full firmware and notice bytes remain unchanged. Native
boot/VRAM/VGA/recovery, log reader, firmware start, IRQ, health and verified
post-submission quiescence remain open. Archive: gsp-run-memory-20260911.

Earlier GA106 core execution and R4OS MMIO binding (host qualification):

`gsp_core` implements reset, start, halt wait and SEC2 resume from the pinned
GA102/TU102 HAL. Reset waits at most 150us for the RESET_READY hint, performs
ten propagation reads after each reset edge, waits for HWCFG2 scrubbing, then
switches core. FALCON_RM receives full BOOT0; CPU start selects the write-only
alias when required. Resume suspends the log reader, selects RISC-V, programs
the retained Libos DMA address, starts SEC2 and checks handoff/mailbox before
restoring logs, FALCON_OS and the active-CPU check. Each call advances one
bounded phase; errors preserve effects and cannot restart the operation.

`gsp_sequencer_port` binds these implementations to actual R4OS MMIO mapping
and sequencer callbacks. It validates the measured uncached BAR0 mapping,
orders volatile accesses and drains posted writes through read-only BOOT0.
The boot owner supplies pure command admission, current register/lockdown
policy, DMA retention, log-reader coordination and real quiescence. A failed
write or cleanup retains the mapping; no timeout grants device quiescence.
See https://docs.kernel.org/driver-api/device-io.html for PCI write ordering.

The existing owner step passes 47/47 cases; one grouped core/MMIO case was
added. All 30 register addresses/fields/constants match original C headers.
These are host models, including the real accessors operating on host memory.
The code is not activated in main.zig or linked into NVIDIA 0.1.25. Native
boot/VRAM/VGA/recovery/log owners, first firmware upload/start, IRQ and health
remain open. No guest run or hardware contact. Archive gsp-core-20260911
retains 205 complete originals/notices. Future executable linkage must extend
the packaged MIT notices before distribution. Subversion 0.79.10 remains open.

Earlier sequencer checkpoint (host):

The host-qualified `gsp_sequencer.DispatchExecution` now holds a CPU-sequencer
boot event through complete execution. It checks all nine opcode forms, operand
extents, register alignment/aperture, save slots and mandatory delay totals
before the first hardware access. A pure native-port admission callback must
accept every instruction. Missing core support rejects the entire program.

Each step performs one instruction, one poll sample or one architecture phase.
Register modify keeps the original `(old & ~mask) | value` semantics. Polls and
delays use microseconds: the actual NVIDIA timeoutSet ABI/multiplication takes
precedence over an old MS header comment. Fixed phase deadlines stay within the
boot deadline; wait_until returns scheduling work without sleeping or spinning.
Core operations retain phase state and require actual completion by the native
port. GA106 resume needs its SEC2/RISC-V/boot-argument path. It is not replaced
by a generic core-start callback that reports success.

Every deferred step revalidates the pending boot ticket. Only complete effects
permit one queue acknowledgement. Ambiguous effects, expired/stale lifetimes
or failed acknowledgements cannot replay the program. Word/opcode, vendor poll
error, last register value and callback error remain available. No memory is
freed and completion does not prove device quiescence. Native register ports
must enforce the boot owner's lockdown restrictions and MMIO ordering.

The existing owner step passes 46 cases, with one added grouped composition
case. All nine opcode/operand forms match the complete original C types/macros
in an 88-byte stream; the existing six event fixtures also pass. The archive
`gsp-sequencer-20260911` contains 185 complete original files/notices. This is
host qualification using register/core-phase models. Real MMIO, Falcon/SEC2
handlers, native launch/IRQ, health and recovery remain open. NVIDIA0.1.25 and
its packaged notices are unchanged; no guest run or hardware update occurred.
Executable linkage must add all new full MIT notices to the package.

Earlier boot-event checkpoint (host):

The host-qualified `gsp_boot_events.Boot` now processes the six pinned startup
notification types over `gsp_transport.Session`. It admits exact fixed layouts
and bounded inline/flexible payloads, preserving raw RPC status fields and
binary log data. One absolute deadline covers connection and deferred handling.
Each call receives at most one record. A matching ticket can be acknowledged
only after the execution/logging owner actually handled it. Sequencer payload
admission does not execute or authorize its opcodes. Unknown events, nonzero
guest IDs, invalid payloads and failed INIT_DONE results stop the session.

Lockdown restricts register access as soon as its notice is admitted; clearing
it requires an unambiguous acknowledgement. INIT_DONE is accepted only after
a zero result and completed acknowledgement. It is not a GPU health, scanout
or quiescence proof. Failed/late acknowledgements retain dispatch and receipt;
handlers must not be replayed. There is no new allocator, wait loop or reset.

At the boot-event checkpoint the owner step passed 45 cases with one added group.
Six fixtures built with complete original NVIDIA C types and the original
checksum agree with the decoder, including inline 1208-byte NOCAT data and
the one-byte lockdown flag. Both final checks pass. No new gate,
guest run, hardware update or module build was needed: this core is not yet
linked into NVIDIA.R4D0.1.25. Native launch/IRQ integration, sequencer execution,
log handling and health checks remain open. The 181 complete source/notice
references are in `gsp-boot-events-20260911`; executable linkage must add all
codec/transport/event notices to the distributed license bundle.

Earlier DMA-port checkpoint (module0.1.25):

`gsp_init_storage.QueueLease` now binds the transport port to DriverApi34.
One admitted execution owner borrows the staged 516-KB queue mapping with a
nonwrapping lease epoch. Reads synchronize the exact range before copying;
publication copies before device synchronization. Bounds and aliases of the
entire allocation are rejected. Old leases and failed I/O cannot keep using
the mapping. An outstanding lease blocks teardown of all seven init mappings,
pins and backing. A latch must be set before any future GPU submission and
currently has no production clear operation; errors do not prove quiescence.

NVIDIA 0.1.25 boot-check reads only the two 32-byte queue headers through this
port, validates initial geometry and the zero status header, then releases
the lease and all dependent storage before returning to bootfb. OssiPC with
Kernel 0.1.148 confirms these actual range acquisitions and complete cleanup.
After two update boots the exact original passive configuration was restored.
No GPU message, firmware start or new picture/sound acceptance occurred.

At the DMA-port checkpoint, the owner step passed 44 cases, including real Storage/SDK/Session
composition against direct and separate bounce-memory host models. The final
module also passes the existing SMP4 passive fallback probe in 20.41 seconds.
Lease identity is not yet a hardware reset generation. Real GSP traffic,
RPC/IRQ, native quiescence/release and VRAM/VGA recovery remain open.

Earlier transport-core checkpoint (host model):

The host-qualified `gsp_transport.zig` owns one cleartext GA106 queue session
over an explicit synchronous range-I/O port. One execution owner borrows two
64-KB scratch buffers. Connection makes one readiness attempt with a deadline
that later attempts cannot extend; each operation checks the real port epoch
and monotonic limit before and after I/O. Payload ranges finish publication
before the four-byte producer cursor. Full validation yields a receipt whose
explicit acknowledgement alone advances the consumer cursor and RX sequence.
Unknown RPC functions/results remain opaque; nothing is automatically dropped.

Impossible peer progress is refused. Errors after a possibly completed copy,
cursor store or acknowledgement latch failure and prohibit retries. Pending
receipts remain retained; no reset/free operation can invent device quiescence.
Protocol u32 sequences wrap; generation-bound u64 receipt identities never do.
At that checkpoint the owner step passed 43 cases, including one grouped transport case
with all swap routes, maximum frames across ring end, full queues, fourteen
before/after callback failures, late deadline/generation loss and stale acks.

That checkpoint used a host port and kept NVIDIA0.1.24 unchanged. The current
Storage/DriverApi34 binding is described above. The source retains the full
MIT notice from the pinned message_queue_cpu.c. Executable codec/Session
integration must include all message/ring/transport notices in the bundle.

Earlier ring and message checkpoints (host qualification):

The host-qualified `gsp_ring.zig` layer admits command/status geometry and
computes swap routing using each side's own RX-header offset. A zero peer
header means not ready; unknown flags, invalid offsets/counts and out-of-range
cursors are refused. The pinned queues hold 256 KB each, normally 63 slots
with one slot reserved. Transfers cover at most 16 slots and two contiguous
spans, including wraparound. Gathering accepts a complete validated message;
scattering leaves the CPU queue shadow unchanged on admission failure.
Neither operation publishes a cursor, sequence, acknowledgement or live link.

At the ring checkpoint, the owner step passed 42 cases. Eight fixtures match actual
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
