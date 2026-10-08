// Nouveau/drivers/gpu/drm/nouveau/nvkm/subdev/gsp/rm/r570/client.c
// /* SPDX-License-Identifier: MIT
//  *
//  * Copyright (c) 2025, NVIDIA CORPORATION. All rights reserved.
//  */
//
// Original Linux MIT license text:
// MIT License
//
// Copyright (c) <year> <copyright holders>
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
//! Resident post-INIT_DONE owner for RM discovery, object creation and events.
//! Queue work is serialized; object handles do not imply native display takeover.
//! Every message uses the actual retained native port and its exact receipt.
const std = @import("std");
const r4os = @import("r4os");
const native = @import("gsp_sequencer_port.zig");
const boot = @import("gsp_boot_events.zig");
const exchange = @import("gsp_exchange.zig");
const events = @import("gsp_runtime_events.zig");
pub const hotplug = @import("gsp_hotplug.zig");
pub const diagnostics = @import("gsp_faults.zig");
const logs = @import("gsp_logs.zig");
const init = @import("gsp_init.zig");
const static = @import("gsp_static.zig");
const postinit = @import("gsp_postinit.zig");
const rm = @import("gsp_rm_graph.zig");
const display = @import("gsp_display_rpc.zig");
pub const sor_assignment = @import("gsp_sor_assignment.zig");
pub const display_engine = @import("gsp_display_engine.zig");
pub const DisplayEngineHandle = struct { epoch: u64, root: u32 };
pub const DisplayEngineStatus = struct { state: display_engine.State, info: ?display_engine.Info, rejected: ?u32, unavailable: bool };
pub const SorAssignmentResult = struct {
    root: DisplayEngineHandle, sequence: u64, generation: u64, receipt: u64,
    source: output_route.Assignment, crossbar: bool, assignment: ?sor_assignment.Assignment,
    rejected: ?u32, rpc_error: bool, obsolete: bool,
};
pub const mode_control = @import("gsp_mode_control.zig");
pub const ModeControlHandle = struct { epoch: u64, handle: u32 };
pub const ModeControlStatus = struct { state: mode_control.State, info: ?mode_control.Result, rejected: ?u32, unavailable: bool };
pub const display_channel = @import("gsp_display_channel.zig");
pub const DisplayChannelHandle = struct { epoch: u64, handle: u32, slot: u8 };
pub const DisplayChannelStatus = struct { state: display_channel.State, info: ?display_channel.Info, rejected: ?u32, host_rejected: ?anyerror, initialized: bool, completed: u64 };
pub const display_resources = @import("gsp_display_resources.zig");
pub const display_upload = @import("gsp_display_upload.zig");
const DisplayResourcesSlot = struct { owner: ?*display_resources.Owner = null, allocation: r4os.abi.DriverHeapAllocation = .{}, heap: ?r4os.r4dev.DriverHeapContext = null };
pub const DisplayTableStatus = struct { entries: u32, revision: u64, published_revision: u64, uploading: bool };
pub const DisplayPhase = enum { prepare, rewind, submitted, complete };
pub const DisplaySubmission = struct {
    handle: DisplayChannelHandle,
    notifier: *display_resources.notifier.Owner,
    config: display_channel.push.commands.Config,
    phase: DisplayPhase = .prepare,
    ticket: ?display_channel.push.Ticket = null,
    pending_cursor_observed: bool = false,
    cursor_head_observed: bool = false,
};
pub const PositionSubmission = struct {
    handle: DisplayChannelHandle,
    config: display_channel.push.commands.Config,
    phase: DisplayPhase = .prepare,
    ticket: ?display_channel.push.Ticket = null,
};
pub const DisplayPosition = struct { handle: DisplayChannelHandle, point: display_channel.push.commands.Point, sequence: u64 };
pub const boot_mode = @import("gsp_boot_mode.zig");
pub const output_route = @import("gsp_output_route.zig");
pub const display_link = @import("gsp_display_link.zig");
pub const display_audio = @import("gsp_display_audio.zig");
pub const DisplayLink = struct {
    plan: display_link.Plan, acknowledged: u8, receipt: u64, dp: ?display_link.dp.Result = null, frl: ?display_link.frl.Result = null,
    mst: ?display_link.mst.Result = null,
    pub fn complete(self: DisplayLink) bool {
        if (self.receipt == 0) return false;
        if (self.plan.transport == .mst) return self.dp == null and self.frl == null and self.mst != null and
            self.acknowledged == 2 and self.mst.?.rate_receipt == self.receipt and self.mst.?.complete(self.plan.transport.mst);
        if (self.mst != null or self.plan.mode.signal.mst != null) return false;
        if (self.plan.mode.signal.hdmi_frl != (self.frl != null)) return false;
        if (self.frl) |proof| if (proof.rate == .none or proof.source_max == .none or proof.training_receipt == 0 or
            !std.meta.eql(proof.compressed, self.plan.mode.signal.hdmi_dsc) or
            (proof.compressed != null and proof.capacity_receipt <= proof.training_receipt)) return false;
        if (self.plan.mode.displayPort()) return self.dp != null and self.acknowledged != 0 and self.dp.?.complete(self.plan.mode);
        return self.dp == null and self.acknowledged == @as(u8, if (self.plan.mode.transport_hdmi) 7 else 2);
    }
    pub fn audio48k(self: DisplayLink) bool {
        if (!self.complete()) return false;
        if (self.mst) |value| return value.demand.audio_48k and self.plan.mode.head < 4;
        if (self.dp) |value| return value.stream.audio_48k;
        return self.plan.mode.transport_hdmi;
    }
};
pub const DisplayAdmission = struct { mode: boot_mode.Plan, link: display_link.Plan, receipt: u64, receiver_sequence: u64 };
pub const refresh_control = @import("gsp_vrr_control.zig");
pub const RefreshCommit = struct { sequence: u64, receiver_sequence: u64, control: refresh_control.Work, failure: ?anyerror = null };
pub const RefreshResult = struct { sequence: u64, plan: refresh_control.Plan, enabled: bool, core_point: u64, receipt: u64, failure: ?anyerror = null };
pub const DisplayLinkFailure = struct {
    mode: boot_mode.Plan, candidate: u32, reason: anyerror, receipt: u64, restored_receipt: u64 = 0,
    previous: ?ActiveDisplayImage, retired: ?DisplayRetirement,
};
pub const DisplayLinkRecovery = struct {
    control: display_link.Work, failure: DisplayLinkFailure, abandoned: bool = false,
    // Only MST may need to restore Core/Window after ACT/branch failure.
    // Once replaced, the ordinary submissions below hold the actual repair.
    scanout_replaced: bool = false,
    repair_offset: ?u16 = null,
};
pub const DisplayWork = struct {
    core: DisplaySubmission, window: ?DisplaySubmission = null, position: ?PositionSubmission = null, deadline: u64,
    ownership: ?DisplaySubmission = null,
    wake_before_link: bool = false, wake_sequence: u64 = 0, wake_receipt: u64 = 0, wake_failure: ?anyerror = null,
    boot_mode: ?boot_mode.Plan = null, mode_receipt: u64 = 0, link: ?display_link.Work = null,
    link_restore: ?DisplayLinkRecovery = null, link_stop: ?display_link.Work = null,
    cursor: ?CursorCommit = null, detach: ?ActiveDisplayImage = null, admission: ?DisplayAdmission = null, refresh: ?RefreshCommit = null,
    pub fn linkControl(self: *DisplayWork) ?*display_link.Work {
        if (self.link_restore) |*restore| return &restore.control;
        if (self.link_stop) |*stop| return stop;
        return if (self.link) |*link| link else null;
    }
    fn ownershipInFlight(self: *const DisplayWork) bool {
        return if (self.ownership) |part| part.phase != .complete and part.ticket != null else false;
    }
};
pub const DisplayRetirement = struct { epoch: u64, image: ActiveDisplayImage, core_point: u64, window_point: u64, observed_ns: u64, link_stop_receipt: u64 = 0 };
pub const cursor_image = @import("gsp_cursor_image.zig");
pub const CursorCommit = struct { control: cursor_image.Control, sequence: u64, baseline: ?@import("gsp_head_events.zig").Sample = null, completed_ns: u64 = 0 };
pub const CursorReady = struct { plan: cursor_image.Plan, point: u32 };
pub const CursorStorage = struct { dma: u32, head: u32, uploaded: [2]?CursorReady = @splat(null), active: ?u1 = null,
    issued: u64 = 0, completed: u64 = 0, control: ?cursor_image.Control = null, upload_error: ?anyerror = null };
pub const CursorUpload = struct { operation: @import("gsp_cursor_upload.zig").Upload = .{}, channel: ChannelHandle, slot: u1 };
pub const ActiveDisplayImage = struct { image: display_resources.image.Image, head: u32, core_point: u64, window_point: u64, boot_mode: ?boot_mode.Plan = null, mode_receipt: u64 = 0, position: ?DisplayPosition = null, link: ?DisplayLink = null, wake_sequence: u64 = 0, wake_receipt: u64 = 0 };
const DigitalMonitorSleep = struct { object: @import("gsp_display_rpc.zig").Object, display_id: u32, head: u32, sor: u32, receipt: u64 };
pub const flip = @import("gsp_flip.zig");
pub const DisplayFlip = struct {
    window: DisplaySubmission,
    presentation: *Presentation,
    previous: ActiveDisplayImage,
    deadline: u64,
    baseline: @import("gsp_head_events.zig").Sample = .{},
    receipt: flip.Receipt,
    ordinary: bool = false,
    retiring_activation: bool = false,
    diagnostic_irq_timeout: bool = false,
};
const subscriptions = @import("gsp_event_objects.zig");
const outputs = @import("gsp_outputs.zig");
const inventory = @import("gsp_memory_inventory.zig");
pub const buffer_mapping = @import("gsp_buffer_mapping.zig");
pub const vram = @import("gsp_vram.zig");
pub const execution_fifo = @import("gsp_fifo.zig");
pub const ChannelHandle = struct { epoch: u64, serial: u64, slot: u16 };
pub const ChannelStatus = struct { state: execution_fifo.State, info: ?execution_fifo.Info, rejected: ?u32, host_rejected: ?anyerror };
pub const GraphicsReceipt = struct { channel: ChannelHandle, point: u32, completed_ns: u64 };
pub const render = @import("r4nv_render");
pub const render_cache = @import("gsp_render_cache.zig");
const render_job = @import("gsp_render_job.zig");
const render_queue = @import("gsp_render_queue.zig");
const native_queue = @import("gsp_native_queue.zig");
pub const scheduling = @import("gsp_work_scheduling.zig");
pub const power = @import("gsp_power.zig");
pub const GraphicsWork = struct {
    channel_handle: ChannelHandle,
    command: execution_fifo.copy.graphics.Command,
    deadline: u64,
    ticket: ?execution_fifo.copy.Ticket = null,
    submitted: bool = false,
    receipt: ?GraphicsReceipt = null,
    resources: render_job.Owner = .{},
    queued: bool = false,
    diagnostic_timeout: bool = false,
};
pub const batch_job = @import("gsp_batch_job.zig");
pub const BatchWork = struct {
    channel_handle: ChannelHandle,
    deadline: u64,
    native_fence: ?r4os.abi.GfxFence = null,
    resources: batch_job.Owner = .{},
    ticket: ?execution_fifo.copy.Ticket = null,
    submitted: bool = false,
    receipt: ?GraphicsReceipt = null,
};
const ChannelSlot = struct { owner: ?*execution_fifo.Owner = null, allocation: r4os.abi.DriverHeapAllocation = .{}, heap: ?r4os.r4dev.DriverHeapContext = null, serial: u64 = 0 };
const CopyAddress = struct { address: u64, bytes: u64 };
pub const present = @import("gsp_present.zig");
pub const Presentation = struct {
    surface: present.Owner = .{}, channel_handle: ChannelHandle, root: DisplayEngineHandle, window: DisplayChannelHandle,
    binding: r4os.abi.GfxBackendBinding = .{}, pending: bool = false, registered: bool = false,
    initial_point: u32 = 0,
    initial_failure: ?anyerror = null,
    retiring: bool = false,
    damage: ?present.Rect = null,
    render_fence: r4os.abi.GfxFence = .{},
    direct: ?struct { job: r4os.abi.GfxDriverJob, handed_off: bool = false, retire_requested: bool = false } = null,
};
pub const InitialImage = struct { operation: present.Initial = .{}, mapping: ?BufferHandle = null, presentation: *Presentation, deadline: u64 };
pub const InitialImageStatus = struct { pending: bool, completed: u32, failure: ?anyerror };
pub const ReadyImage = struct { image: *Presentation, deadline: u64 };
pub const FrameCounters = struct { acquired: u64 = 0, rendered: u64 = 0, rejected: u64 = 0,
    submitted: u64 = 0, visible: u64 = 0, released: u64 = 0 };
const DeferredPresentation = struct { job: r4os.abi.GfxDriverJob, deadline: u64 };
pub const CopyJob = struct {
    queue: r4os.driver_queue.Context,
    memory: r4os.driver_memory.Context,
    channel_handle: ChannelHandle,
    binding: r4os.abi.GfxBackendBinding,
    job: r4os.abi.GfxDriverJob,
    job_stamp: r4os.abi.GfxDriverJob,
    deadline: u64,
    references: [2]r4os.abi.GfxBufferReference = @splat(.{}),
    addresses: [2]?CopyAddress = @splat(null),
    mappings: [2]?BufferHandle = @splat(null),
    ticket: ?execution_fifo.copy.Ticket = null,
    submitted: bool = false,
    presentation: bool = false,
    diagnostic_timeout: bool = false,
    output_window: ?u3 = null,
    transfer: ?execution_fifo.copy.wire.Transfer = null,
    copied: u64 = 0,
    slice_end: u64 = 0,
    target_presentation: ?*Presentation = null,
    render_read: present.Initial = .{},
};
const WorkSlot = union(enum) { free, copy: CopyJob, render: render_queue.Owner, native: native_queue.Job };
pub const execution_context = @import("gsp_context.zig");
pub const ContextHandle = struct { epoch: u64, serial: u64, slot: u16 };
pub const ContextStatus = struct { state: execution_context.State, info: ?execution_context.Info, rejected: ?u32, unavailable: ?execution_context.Unavailable };
const ContextSlot = struct { owner: ?*execution_context.Owner = null, allocation: r4os.abi.DriverHeapAllocation = .{}, heap: ?r4os.r4dev.DriverHeapContext = null, serial: u64 = 0 };
pub const BufferHandle = struct { epoch: u64, serial: u64, slot: u32 };
pub const virtual_resources = @import("gsp_virtual_resources.zig");
pub const VirtualHandle = virtual_resources.Handle;
pub const VirtualBindingHandle = virtual_resources.BindingHandle;
pub const VirtualStatus = struct { state: virtual_resources.range.State, info: ?virtual_resources.range.Info, rejected: ?u32 };
pub const VirtualBindingStatus = struct { mapped: bool, bytes: u64, rejected: ?u32 };
pub const VirtualSource = union(enum) { system: BufferHandle, native: BufferHandle, native_reference: r4os.abi.GfxBufferReference };
pub const BufferStatus = struct { state: buffer_mapping.State, info: ?buffer_mapping.Info, rejected: ?u32, host_rejected: ?buffer_mapping.Error };
const copy_mapping_idle_ns = 250 * std.time.ns_per_ms;
const BufferSlot = struct {
    owner: ?*buffer_mapping.Owner = null,
    allocation: r4os.abi.DriverHeapAllocation = .{},
    heap: ?r4os.r4dev.DriverHeapContext = null,
    serial: u64 = 0,
    pending_source: r4os.abi.GfxBufferReference = .{},
    cacheable: bool = false,
    last_used: u64 = 0,
    last_used_ns: u64 = 0,
    evicting: bool = false,
    public_users: u64 = 0,
};
pub const NativeBufferStatus = struct { state: vram.State, info: ?vram.Info, rejected: ?u32, host_rejected: ?i32 };
const NativeBufferSlot = struct { owner: ?*vram.Owner = null, allocation: r4os.abi.DriverHeapAllocation = .{}, heap: ?r4os.r4dev.DriverHeapContext = null, serial: u64 = 0 };
const ResourceSlots = @import("gsp_resource_slots.zig");
const BufferStorage = struct { owner: buffer_mapping.Owner, names: @import("gsp_rm_names.zig").ResidentChildren };
const NativeBufferStorage = struct { owner: vram.Owner, names: @import("gsp_rm_names.zig").ResidentChildren };
pub const Progress = enum { idle, progress };
pub const Snapshot = struct {
    polls: u64 = 0,
    events: u64 = 0,
    sequencers: u64 = 0,
    xid_count: u64 = 0,
    last_xid: u32 = 0,
    nocat_count: u64 = 0,
    raw_words: u64 = 0,
    lost_words: u64 = 0,
    moving_logs: u64 = 0,
    last_poll_ns: u64 = 0,
    last_event_ns: u64 = 0,
    hotplug_events: u64 = 0,
    dp_irq_events: u64 = 0,
};
pub const Owner = struct {
    self_address: usize = 0,
    ctx: ?r4os.r4dev.DriverContext = null,
    device: ?*native.Port = null,
    reader: ?*logs.Reader = null,
    channel: ?exchange.Exchange = null,
    ordinary: ?events.Dispatch = null,
    sequence: native.RuntimeSequencer = .{},
    epoch: u64 = 0,
    adapter_id: u32 = 0,
    last_clock: u64 = 0,
    next_log: u64 = 0,
    log_index: usize = 0,
    snapshot: Snapshot = .{},
    failure: ?anyerror = null,
    protocol_failure: ?exchange.Error = null,
    static_request: [static.payload_bytes]u8 = @splat(0),
    static_info: ?static.Info = null,
    reservation: ?*const @import("boot_vram_lease.zig").Lease = null,
    // Only the new epoch's actual console owner selects firmware transport.
    // A pending old common restore callback also occurs during native reset.
    boot_console_restore: ?*const @import("boot_console.zig").Owner = null,
    memory_inventory: inventory.Owner = .{},
    user_vram: @import("gsp_user_vram.zig").Owner = .{},
    memory_admission: @import("gsp_residency.zig").Admission = .{},
    physical_bytes: u64 = 0,
    startup_deadline: u64 = 0,
    post: postinit.Owner = .{},
    rm_enabled: bool = false, // Set by the real device only after IRQ installation.
    power_enabled: bool = false,
    power_owner: ?power.Owner = null,
    power_active: bool = false,
    graph: ?rm.Owner = null,
    display_object: ?display.Object = null,
    display_engine_owner: ?display_engine.Owner = null,
    display_engine_active: bool = false,
    mode_control_owner: ?mode_control.Owner = null,
    mode_control_active: bool = false,
    mode_control_root: ?DisplayEngineHandle = null,
    display_channels: [25]?display_channel.Owner = @splat(null),
    display_channel_active: ?u8 = null,
    cursor_point: ?u8 = null,
    display_resources_slot: DisplayResourcesSlot = .{},
    display_upload_job: ?struct { operation: display_upload.Upload = .{}, channel_handle: ChannelHandle } = null,
    display_work: ?DisplayWork = null,
    display_routes: [8]?u32 = @splat(null),
    refresh_results: [8]?RefreshResult = @splat(null),
    refresh_clocks: [8]@import("gsp_refresh_pacing.zig").State = @splat(.{}),
    refresh_quiescing: bool = false,
    refresh_sequence: u64 = 0,
    display_flips: [8]?DisplayFlip = @splat(null),
    flip_serials: [8]u64 = @splat(0),
    flip_cursor: u3 = 0,
    flip_issued: u64 = 0,
    flip_visible: u64 = 0,
    flip_released: u64 = 0,
    flip_receipts: [8]?flip.Receipt = @splat(null),
    head_events: ?*const @import("gsp_head_events.zig").Owner = null,
    display_images: [8]?ActiveDisplayImage = @splat(null),
    display_link_failures: [8]?DisplayLinkFailure = @splat(null),
    display_retired: [8]?DisplayRetirement = @splat(null),
    output_claims: [8]?output_route.Claim = @splat(null),
    sor_work: ?sor_assignment.Work = null,
    sor_root: ?DisplayEngineHandle = null,
    sor_result: ?SorAssignmentResult = null,
    sor_boot: ?struct { plan: boot_mode.Plan, identity: output_route.RestoreIdentity } = null,
    sor_sequence: u64 = 0,
    display_paused: bool = false,
    additional_restoring: [8]bool = @splat(false),
    mode_mailbox: ?r4os.abi.GfxDriverModeJob = null,
    display_restoring: bool = false,
    display_cancelled: u64 = 0,
    flip_cancelled: u64 = 0,
    presentation_slots: [8 * 6]?Presentation = @splat(null),
    presentation: ?*Presentation = null,
    additional_presentations: [8]?*Presentation = @splat(null),
    additional_paused: [8]bool = @splat(false),
    presentation_targets: [8]?r4os.abi.GfxOutputTarget = @splat(null),
    presentation_buffers: u8 = 0,
    frame_setup: ?@import("gsp_frame_setup.zig").Work = null,
    frame_ready: ?ReadyImage = null,
    additional_ready: [8]?ReadyImage = @splat(null),
    // Only canonical, unsubmitted queue values may move. The common queue
    // retains their BOs; CopyJob's mappings and self-pointers stay resident.
    deferred_presentations: [16]?DeferredPresentation = @splat(null),
    deferred_cursor: u4 = 0,
    ready_cursor: u3 = 0,
    direct_work: ?@import("gsp_direct_present.zig").Work = null,
    direct_step: bool = false,
    direct_enabled: bool = false,
    require_mode_receipt: bool = false,
    initial_image: ?InitialImage = null,
    audio_work: ?display_audio.Work = null,
    audio_result: ?display_audio.Result = null,
    audio_sequence: u64 = 0,
    monitor_work: ?@import("gsp_monitor_power.zig").Work = null,
    monitor_result: ?@import("gsp_monitor_power.zig").Result = null,
    monitor_sequence: u64 = 0,
    digital_monitor_sleep: [8]?DigitalMonitorSleep = @splat(null),
    cursor_storage: ?CursorStorage = null,
    cursor_upload: ?CursorUpload = null,
    cursor_reserving: bool = false,
    rm_rejection: ?u32 = null,
    outputs: outputs.Owner = .{},
    // Headless execution retains GSP/RM/IRQ and GPU engines, but performs no
    // connector probing, EDID/DDC, AUX or link training, including on HPD.
    discover_receivers: bool = true,
    receiver_events: hotplug.Work = .{},
    output_generation: u64 = 0,
    buffers: ResourceSlots.Pool(BufferSlot) = .{},
    public_import: @import("gsp_common_reference.zig").Owner = .{},
    buffer_active: ?u32 = null,
    buffer_serial: u64 = 0,
    mapping_evictions: u64 = 0,
    residency_rejections: u64 = 0,
    native_buffers: ResourceSlots.Pool(NativeBufferSlot) = .{},
    native_active: ?u32 = null,
    virtuals: virtual_resources.Owner = .{},
    allocations: @import("gsp_allocation.zig").Owner = .{},
    virtual_provider: @import("gsp_virtual_provider.zig").Owner = .{},
    fifos: [execution_fifo.wire.host_channel_slots]ChannelSlot = @splat(.{}),
    fifo_active: ?u16 = null,
    work_slots: [scheduling.capacity]WorkSlot = @splat(.free),
    work_schedule: scheduling.Owner = .{},
    active_work: ?usize = null,
    copy_job: ?*CopyJob = null,
    // Explicit headless diagnostic only. Consumed by one public CE submit;
    // rebuilding Owner does not rearm it. Hardware completion is not forged.
    diagnostic_copy_timeout: bool = false,
    // Same bounded observation probe for one public draw. Startup barriers,
    // shader uploads and all submitted command/shader bytes remain unchanged.
    diagnostic_render_timeout: bool = false,
    // Native diagnostic only: withhold the first submitted flip's use of
    // head observations. IRQ dispatch, Window execution and DMA stay real.
    // The ordinary deadline/retention path and one-shot reset remain owners.
    diagnostic_flip_irq_timeout: bool = false,
    graphics_work: ?GraphicsWork = null,
    batch_work: ?BatchWork = null,
    graphics_cache: render_cache.Owner = .{},
    queued_render: ?*render_queue.Owner = null,
    queued_native: ?*native_queue.Job = null,
    native_queues: native_queue.Owner = .{},
    graphics_channel: ?ChannelHandle = null,
    graphics_copy_channel: ?ChannelHandle = null,
    graphics_enabled: bool = false,
    graphics_starting: bool = false,
    graphics_completed: u64 = 0,
    graphics_upload: ?struct { channel: ChannelHandle, queued: bool = false, operation: @import("gsp_render_upload.zig").Owner = .{} } = null,
    copy_completed: u64 = 0,
    copy_bytes: u64 = 0,
    copy_row_jobs: u64 = 0,
    frames_acquired: u64 = 0,
    frames_rendered: u64 = 0,
    frames_rejected: u64 = 0,
    output_frames: [8]FrameCounters = @splat(.{}),
    output_faults: [8]?anyerror = @splat(null),
    preparing_outputs: u32 = 0,
    native_copy: @import("gsp_native_copy.zig").Owner = .{},
    copy_backend: ?struct {
        queue: r4os.driver_queue.Context,
        binding: r4os.abi.GfxBackendBinding,
        channel: ?ChannelHandle = null,
        operations: u64 = 9,
        pending: bool = false,
    } = null,
    quarantine_attempted: bool = false,
    quarantine_result: ?i32 = null,
    faults: diagnostics.Journal = .{},
    contexts: [64]ContextSlot = @splat(.{}),
    context_active: ?u16 = null,
    graph_closing: bool = false,
    shutdown_closing: bool = false,
    memory_api: ?r4os.driver_memory.Context = null,
    close_deadline: u64 = 0,
    unload: @import("gsp_unload.zig").Owner = .{},
    reset_stage: enum { loss, queue, transfers, work, presentations, virtuals, fifos, display_channels, display_resources,
        contexts, control, mappings, virtual_provider, native, done } = .loss,
    reset_cursor: usize = 0,
    words: [logs.output_bytes]u8 = undefined,

    pub fn open(self: *Owner, ctx: *const r4os.r4dev.DriverContext, device: *native.Port,
        handoff: *boot.Handoff, reader: *logs.Reader, reservation: *const @import("boot_vram_lease.zig").Lease, deadline: u64) !void
    {
        if (self.self_address != 0) return error.Busy;
        if (self.adapter_id == 0) return error.Binding;
        if (device.phase != .runtime or device.runtime_session != handoff.session or
            reader.memory == null or device.owner == null or device.owner.?.queue_memory != reader.memory or
            reader.generation() != handoff.session.epoch or !reader.enabled or reader.busy or
            reservation.backing != reader.memory.?.boot_storage) return error.Binding;
        self.self_address = @intFromPtr(self);
        self.ctx = ctx.*;
        self.memory_api = ctx.memory() orelse return error.Api;
        self.device = device;
        self.reader = reader;
        self.reservation = reservation;
        self.epoch = handoff.session.epoch;
        self.receiver_events.epoch = self.epoch;
        self.startup_deadline = deadline;
        errdefer |err| self.failure = err;
        self.channel = try exchange.Exchange.init(handoff, deadline);
        const opened_at = try self.now();
        self.next_log = opened_at +| std.time.ns_per_s;
        self.physical_bytes = (device.owner.?.queue_memory.?.boot_storage.?.vram_plan orelse return error.Binding).fb_bytes;
        // Nouveau's bare-metal570 path queries this directly after INIT_DONE;
        // no vGPU guest-version handshake is needed. One fixed request budget
        // also covers interleaved notifications and lockdown; never retry TX.
        try self.channel.?.begin(static.function, &self.static_request,
            @min(deadline, try std.math.add(u64, opened_at, 5 * std.time.ns_per_s)));
    }
    fn now(self: *Owner) !u64 {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.failure != null) return error.State;
        const device = self.device orelse return error.State;
        const channel = self.activeChannel() orelse return error.State;
        if (device.phase != .runtime or device.runtime_session != channel.session or
            channel.session.epoch != self.epoch or channel.session.port.generation(channel.session.port.context) != self.epoch) return error.Stale;
        const current = channel.session.port.now_ns(channel.session.port.context);
        if (current == std.math.maxInt(u64) or current < self.last_clock) return error.Clock;
        self.last_clock = current;
        return current;
    }
    pub fn clock(self: *const Owner) ?r4os.r4dev.DriverResourceContext {
        const device = self.device orelse return null;
        return device.clock;
    }
    /// Kernel terminal admission has already closed new common work. Keep
    /// existing engine/RM receipts live while the physical work drains.
    pub fn beginShutdown(self: *Owner) !void {
        if (self.shutdown_closing) return;
        const current = try self.now();
        if (self.nativeObject() == null or self.display_engine_owner != null or self.mode_control_owner != null or
            self.presentation != null or self.allocations.pending != null or self.native_copy.phase != .ready)
            return error.ShutdownStartup;
        const memory = self.memory_api orelse return error.Api;
        if (memory.deviceLost(self.adapter_id, self.epoch, false) != r4os.abi.gfx_buffer_result_ok) return error.Retained;
        self.shutdown_closing = true;
        // Set the firmware-lifetime policy before another Work slice can
        // choose telemetry teardown while outstanding GPU work drains.
        if (self.power_owner) |*owner| _ = try owner.stopForFirmwareUnload(current);
        self.allocations.close();
        self.virtual_provider.close();
    }
    pub fn shutdownGraph(self: *Owner, deadline: u64) !bool {
        if (!self.shutdown_closing) return error.State;
        if (self.graph_closing) return true;
        if (self.copyBusy() or self.hasQueuedWork() or self.cursor_point != null) return false;
        // This removes only the admission handle. The actual FIFO/context
        // owners remain in the graph and must acknowledge their retirement.
        if (self.copy_backend) |*backend| backend.channel = null;
        self.beginDestroyGraph(deadline, true) catch |err| {
            if (err == error.Busy) return false;
            return err;
        };
        return true;
    }
    pub fn step(self: *Owner) !Progress {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.failure != null) return error.State;
        const progress = self.advance() catch |err| {
            self.stop(err);
            return err;
        };
        return progress;
    }

    /// One bounded cleanup slice. Called only while the device's FLR proof
    /// remains live and bus mastering is disabled. No RM command or GPU
    /// completion is synthesized; the original journal remains inspectable.
    pub fn closeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence) !bool {
        if (!proof.valid(proof.epoch)) return error.Retained;
        if (self.self_address == 0) {
            // Startup may fail before Runtime borrowed any GPU owner.
            self.epoch = proof.epoch;
            self.reset_stage = .done;
            return true;
        }
        if (self.self_address != @intFromPtr(self) or self.failure == null or !proof.valid(self.epoch)) return error.Stale;
        const memory = self.memory_api orelse return error.Api;
        // Closing a consumer can make a native BO's exact release ticket
        // ready. The common collector covers the whole driver epoch, so drain
        // one such ticket before retrying a child storage's collection barrier.
        // No command is sent to the stopped GPU and no consumer lease is cut.
        if (self.reset_stage != .loss and self.reset_stage != .queue and self.reset_stage != .done and
            try self.collectNativeAfterReset(proof)) return false;
        switch (self.reset_stage) {
            .loss => {
                if (memory.deviceLost(self.adapter_id, self.epoch, true) != r4os.abi.gfx_buffer_result_ok) return error.Retained;
                if (!self.allocations.closeAfterReset(proof, self.epoch)) return false;
                self.reset_stage = .queue;
            },
            .queue => {
                if (self.copy_backend) |*backend| {
                    if (self.quarantine_result != r4os.abi.gfx_queue_ok) {
                        const result = backend.queue.unregister(&backend.binding, 1);
                        if (result == r4os.abi.gfx_queue_error_busy) return false;
                        if (result != r4os.abi.gfx_queue_ok) return error.Retained;
                    }
                    self.copy_backend = null;
                }
                self.reset_stage = .transfers;
            },
            .transfers => {
                if (!self.native_copy.probe.closeAfterReset(proof, self.epoch)) return error.Retained;
                if (self.batch_work) |*work| { if (!work.resources.closeAfterReset(proof)) return error.Retained; self.batch_work = null; }
                if (self.graphics_upload) |*work| { if (!work.operation.closeAfterReset(proof)) return error.Retained; self.graphics_upload = null; }
                if (self.graphics_work) |*work| { if (!work.resources.closeAfterReset(proof)) return error.Retained; self.graphics_work = null; }
                if (self.display_upload_job) |*work| { if (!work.operation.closeAfterReset(proof)) return error.Retained; self.display_upload_job = null; }
                if (self.cursor_upload) |*work| { if (!work.operation.closeAfterReset(proof)) return error.Retained; self.cursor_upload = null; }
                if (self.initial_image) |*work| { if (!work.operation.closeAfterReset(proof)) return error.Retained; self.initial_image = null; }
                if (!self.graphics_cache.closeAfterReset(proof)) return error.Retained;
                self.reset_stage = .work; self.reset_cursor = 0;
            },
            .work => {
                if (self.reset_cursor < self.work_slots.len) {
                    const slot = &self.work_slots[self.reset_cursor];
                    switch (slot.*) {
                        .free => {},
                        .render => |*work| if (!work.closeAfterReset(proof, self.epoch)) return error.Retained,
                        .native => |*work| if (!work.closeAfterReset(&self.native_queues, proof, self.epoch)) return error.Retained,
                        .copy => |*work| {
                            if (!std.meta.eql(work.job, work.job_stamp) or !work.render_read.closeAfterReset(proof)) return error.Retained;
                            for (&work.references) |*reference| if (reference.reference.id != 0) {
                                if (work.memory.bufferRelease(&reference.reference) != r4os.abi.gfx_buffer_result_ok) return error.Retained;
                                reference.* = .{};
                            };
                        },
                    }
                    slot.* = .free; self.reset_cursor += 1; return false;
                }
                self.copy_job = null; self.queued_render = null; self.queued_native = null; self.active_work = null;
                self.work_schedule = .{}; self.deferred_presentations = @splat(null);
                self.reset_stage = .presentations; self.reset_cursor = 0;
            },
            .presentations => {
                if (self.reset_cursor < self.presentation_slots.len) {
                    const slot = &self.presentation_slots[self.reset_cursor];
                    if (slot.*) |*owner| if (!owner.surface.closeAfterReset(proof)) return error.Retained;
                    slot.* = null; self.reset_cursor += 1; return false;
                }
                self.presentation = null; self.additional_presentations = @splat(null);
                self.reset_stage = .virtuals;
            },
            .virtuals => {
                // All execution loans above have consumed this same FLR
                // proof. Remove child VA aliases before any channel waits
                // on the whole-driver collector: deviceLost(quiesced) makes
                // their reference-only native BOs pending even while the
                // alias import survives. Parent backing and namespaces stay
                // held until these exact children and receipts retire.
                if (!try self.virtuals.closeAfterReset(proof)) return false;
                self.reset_stage = .fifos; self.reset_cursor = 0;
            },
            .fifos => {
                if (self.reset_cursor < self.fifos.len) {
                    const slot = &self.fifos[self.reset_cursor];
                    if (slot.owner) |owner| owner.closeAfterReset(proof) catch |err| {
                        if (err == error.Retained and owner.awaitingCollection()) return false;
                        return err;
                    };
                    if (slot.allocation.handle != 0) try self.freeChannelSlot(self.reset_cursor);
                    self.reset_cursor += 1; return false;
                }
                self.reset_stage = .display_channels; self.reset_cursor = 0;
            },
            .display_channels => {
                if (self.reset_cursor < self.display_channels.len) {
                    const slot = &self.display_channels[self.reset_cursor];
                    if (slot.*) |*owner| owner.closeAfterReset(proof) catch |err| {
                        if (err == error.Busy) return false;
                        return err;
                    };
                    slot.* = null; self.reset_cursor += 1; return false;
                }
                self.reset_stage = .display_resources;
            },
            .display_resources => {
                const slot = &self.display_resources_slot;
                if (slot.owner) |owner| owner.closeAfterReset(proof) catch |err| {
                    if (err == error.Busy) return false;
                    return err;
                };
                if (slot.allocation.handle != 0 and slot.heap.?.release(slot.allocation.handle) != r4os.abi.driver_heap_ok) return error.Retained;
                slot.* = .{};
                if (self.display_engine_owner) |*owner| { try owner.closeAfterReset(proof); self.display_engine_owner = null; }
                self.reset_stage = .contexts; self.reset_cursor = 0;
            },
            .contexts => {
                if (self.reset_cursor < self.contexts.len) {
                    const slot = &self.contexts[self.reset_cursor];
                    if (slot.owner) |owner| {
                        if (try owner.closeAfterReset(proof)) try self.freeContextSlot(self.reset_cursor);
                    } else if (slot.allocation.handle != 0) try self.freeContextSlot(self.reset_cursor);
                    self.reset_cursor += 1; return false;
                }
                for (&self.contexts) |*slot| if (slot.owner != null) { self.reset_cursor = 0; return false; };
                if (!try self.native_queues.closeAfterReset(proof, self.epoch)) return false;
                self.reset_stage = .control;
            },
            .control => {
                if (self.power_owner) |*owner| {
                    if (!owner.backing.closeAfterReset(proof)) {
                        if (owner.backing.awaitingCollection()) return false;
                        return error.Retained;
                    }
                    self.power_owner = null;
                }
                if (self.graph) |*graph| if (graph.control_buffer) |*owner| {
                    if (!owner.backing.closeAfterReset(proof)) {
                        if (owner.backing.awaitingCollection()) return false;
                        return error.Retained;
                    }
                };
                self.reset_stage = .mappings; self.reset_cursor = 0;
            },
            .mappings => {
                try self.public_import.closeAfterReset(proof);
                if (self.reset_cursor < self.buffers.items().len) {
                    const slot = &self.buffers.items()[self.reset_cursor];
                    if (slot.owner) |owner| owner.closeAfterReset(proof) catch |err| {
                        if (err == error.Retained and owner.awaitingCollection()) return false;
                        return err;
                    };
                    if (slot.pending_source.reference.id != 0) {
                        if (memory.bufferRelease(&slot.pending_source.reference) != r4os.abi.gfx_buffer_result_ok) return error.Retained;
                        slot.pending_source = .{};
                    }
                    if (slot.allocation.handle != 0 and slot.heap.?.release(slot.allocation.handle) != r4os.abi.driver_heap_ok) return error.Retained;
                    slot.* = .{}; self.reset_cursor += 1; return false;
                }
                try self.buffers.closeEmpty();
                self.reset_stage = .virtual_provider;
            },
            .virtual_provider => {
                if (!try self.virtual_provider.closeAfterReset(proof, self.epoch)) return false;
                self.reset_stage = .native; self.reset_cursor = 0;
            },
            .native => {
                if (self.reset_cursor < self.native_buffers.items().len) {
                    const slot = &self.native_buffers.items()[self.reset_cursor];
                    if (slot.owner) |owner| {
                        if (try owner.closeAfterReset(proof)) try self.freeNativeSlot(self.reset_cursor);
                    } else if (slot.allocation.handle != 0) try self.freeNativeSlot(self.reset_cursor);
                    self.reset_cursor += 1; return false;
                }
                var ticket: r4os.abi.GfxOwnedBufferRelease = .{};
                for (self.native_buffers.items()) |*slot| if (slot.owner != null) {
                    const result = memory.bufferTakeRelease(self.adapter_id, self.epoch, &ticket);
                    if (result == r4os.abi.gfx_buffer_error_busy) { self.reset_cursor = 0; return false; }
                    if (result != r4os.abi.gfx_buffer_result_ok) return error.Retained;
                    for (self.native_buffers.items(), 0..) |*candidate, index| if (candidate.owner) |owner| {
                        if (owner.release.attempt != 0 or !owner.acceptsAfterReset(ticket)) continue;
                        owner.release = ticket;
                        self.reset_cursor = index; return false;
                    };
                    return error.Descriptor;
                };
                try self.native_buffers.closeEmpty();
                if (!self.user_vram.empty()) return error.Retained;
                if (self.graph) |*graph| if (graph.address_space) |*space| {
                    if (!try space.host_storage.closeAfterReset(proof)) return false;
                    space.host_vm = .{};
                };
                if (memory.collect() != r4os.abi.gfx_buffer_result_ok) return error.Retained;
                self.reset_stage = .done;
            },
            .done => return true,
        }
        return false;
    }
    /// An unpublished reservation cannot issue a consumer release ticket.
    /// Abort it only after the allocation provider and queue are closed and
    /// FLR proves DMA stopped. Published BOs still require their exact tickets;
    /// the normal native stage closes remaining producer/consumer references.
    fn collectNativeAfterReset(self: *Owner, proof: @import("gsp_reset.zig").Quiescence) !bool {
        const memory = self.memory_api orelse return error.Api;
        var eligible = false;
        for (self.native_buffers.items(), 0..) |*slot, index| if (slot.owner) |owner| {
            if (!owner.committed) {
                // Waiting until the final native stage deadlocks earlier
                // channel collectors on this driver's allocating bytes.
                // The owner authenticates the reservation, namespace and
                // quiescence before aborting; no RM request is replayed.
                if (!try owner.closeAfterReset(proof)) return error.Retained;
                try self.freeNativeSlot(index);
                return true;
            }
            // After deviceLost(quiesced), the common owner may issue a
            // ticket even while an invalid producer/import reference exists.
            // Prepare every published owner before taking any such ticket.
            // Actual backing/namespace retirement still waits for all aliases
            // and the exact release receipt; no GPU completion is inferred.
            if (owner.common_live and (!owner.closing or owner.reference_live)) {
                if (try owner.closeAfterReset(proof)) try self.freeNativeSlot(index);
                return true;
            }
        };
        for (self.native_buffers.items(), 0..) |*slot, index| if (slot.owner) |owner| {
            if (!owner.closing or !owner.common_live) continue;
            eligible = true;
            if (owner.release.attempt == 0 or !owner.aliases.empty()) continue;
            if (!try owner.closeAfterReset(proof)) return error.Retained;
            try self.freeNativeSlot(index);
            return true;
        };
        if (!eligible) return false;
        var ticket: r4os.abi.GfxOwnedBufferRelease = .{};
        const result = memory.bufferTakeRelease(self.adapter_id, self.epoch, &ticket);
        if (result == r4os.abi.gfx_buffer_error_busy) return false;
        if (result != r4os.abi.gfx_buffer_result_ok) return error.Retained;
        for (self.native_buffers.items()) |*slot| if (slot.owner) |owner| {
            if (owner.release.attempt != 0 or !owner.acceptsAfterReset(ticket)) continue;
            owner.release = ticket;
            return true; // Preserve the receipt until the next bounded slice.
        };
        return error.Descriptor; // Unknown issued ticket stays held.
    }
    fn failureOperation(self: *const Owner) diagnostics.Operation {
        // This is retained owner metadata, never a fault-time device probe.
        if (self.power_active) return .power;
        if (self.sequence.self_address != 0) return .firmware;
        if (self.display_channel_active != null) return .display_channel;
        if (self.mode_control_active or self.display_engine_active or self.audio_work != null or self.monitor_work != null or self.sor_work != null) return .display_engine;
        if (self.buffer_active != null) return .mapping;
        if (self.virtuals.active_range != null) return .mapping;
        if (self.native_active != null) return .native_buffer;
        if (self.fifo_active != null) return .channel;
        if (self.context_active != null) return .context;
        if (self.graphics_work != null or self.graphics_upload != null) return .render;
        if (self.display_work != null or self.hasDisplayFlips() or
            self.cursor_upload != null or self.cursor_point != null) return .display_channel;
        if (self.queued_native != null or self.batch_work != null or self.copy_job != null or self.display_upload_job != null or self.initial_image != null) return .submit;
        if (self.queued_render != null) return .render;
        return if (self.graph_closing) .teardown else .event;
    }
    /// Logical shutdown invalidates every borrowed inventory and retains the
    /// existing RM/session resources. It is not physical GPU quiescence.
    pub fn stop(self: *Owner, err: anyerror) void {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.failure != null) return;


        self.logResidency();
        self.allocations.close();
        self.virtual_provider.close();
        if (self.memory_api) |memory| {
            const result = memory.deviceLost(self.adapter_id, self.epoch, false);
            if (result != r4os.abi.gfx_buffer_result_ok and result != r4os.abi.err_no_fn)
                self.log("NVIDIA gsp-quarantine: native-buffers={d} epoch={d}", .{result, self.epoch});
        }
        if (self.power_owner) |*owner| owner.deviceLost(self.last_clock);
        if (self.faults.first_fatal == null and err != error.Stopped and err != error.RmClosed)
            self.recordFault(diagnostics.host(self.failureOperation(), err, true)) catch {};
        self.outputs.invalidate() catch {};
        self.memory_inventory.invalidate();
        if (self.graphics_cache.self_address != 0) self.graphics_cache.failed = true;
        if (self.graphics_upload) |*work| work.operation.failed = true;
        if (self.batch_work) |*work| work.resources.failed = true;
        if (self.graphics_work) |*work| if (work.resources.self_address != 0) { work.resources.failed = true; };
        if (self.display_upload_job) |*work| work.operation.quarantine(err);
        if (self.cursor_upload) |*work| work.operation.quarantine(err);
        if (self.cursor_upload != null or (if (self.display_work) |work| work.cursor != null else false))
            self.log("NVIDIA cursor: failed reason={s} upload-held={} image-unconfirmed={} resources=retained",
                .{@errorName(err), self.cursor_upload != null, if (self.display_work) |work| work.cursor != null else false});
        // Sample the still-valid retained CPU mapping before quarantine.
        // A missing sample stays explicit; never report a sentinel as data.
        if (self.display_work) |*work| if (work.ownership) |*part| {
            const observed: ?u32 = part.notifier.observedWord() catch null;
            self.log("NVIDIA gsp-display-owner: failed={s} phase={s} point={d} kind={s} put={d} notifier={?x} cursor-observed={} storage=retained",
                .{@errorName(err),@tagName(part.phase),if(part.ticket)|ticket|ticket.point else 0,
                    if(part.ticket)|ticket|@tagName(ticket.kind) else "none",if(part.ticket)|ticket|ticket.put else 0,
                    observed,part.pending_cursor_observed});
        };
        if (self.display_resources_slot.owner) |owner| owner.quarantine();
        self.failure = err;
        if (self.outputs.refresh) |*refresh| {
            self.log("NVIDIA gsp-receiver-failed: generation={d} display={x} phase={s} bytes={d} failure={s} resources=retained",
                .{self.outputs.data.generation, refresh.capture.display_id,
                    @tagName(refresh.capture.failure_phase orelse refresh.state), refresh.capture.edid_bytes, @errorName(err)});
            self.logReceiverReplies(self.outputs.data.generation, refresh.capture);
        }
        // Retained CPU-side ownership only; no new query or cleanup action.
        // A graph deadline must identify the broker that still blocks FIFO
        // retirement even when the subsequent reset also fails.
        self.log("NVIDIA gsp-close: shutdown={} graph={} deadline={d} now={d} native-queues={d} queue-spare={d}",
            .{self.shutdown_closing, self.graph_closing, self.close_deadline, self.last_clock,
                self.native_queues.count, self.native_queues.spare.handle});
        self.log("NVIDIA gsp-close-virtual: provider={d} closing={} requested={} pending={} nodes={} spare={d} closed={}",
            .{self.virtual_provider.handle.id, self.virtual_provider.closing, self.virtual_provider.requested,
                self.virtual_provider.pending != null, self.virtual_provider.nodes.root != null,
                self.virtual_provider.spare.handle, self.virtual_provider.closed()});
        if (self.unload.self_address != 0) self.log("NVIDIA gsp-unload: end={s} phase={s} reply={?x} payload-bytes={d} mailbox={?x} polls={d} resources=held",
            .{ @errorName(err), @tagName(self.unload.phase), if (self.unload.reply) |reply| @as(?u32, reply.result) else null,
                self.unload.reply_bytes, self.unload.last_mailbox, self.unload.observations });
        // unregister(false) terminalizes the common queue as device-lost but
        // retains reachable jobs. complete(device_lost, false) is not that API.
        // Keep this binding even between jobs and attempt retirement only once.
        if (self.copy_backend) |*backend| if (!self.quarantine_attempted) {
            self.quarantine_attempted = true;
            self.quarantine_result = backend.queue.unregister(&backend.binding, 0);
            self.log("NVIDIA gsp-quarantine: epoch={d} result={d} quiesced=no job-held={} resources=retained",
                .{self.epoch, self.quarantine_result.?, self.hasQueuedWork()});
        };
        if (self.activeChannel()) |channel| {
            self.protocol_failure = channel.fail(error.Handler);
            // A failed token transition can leave only handed-off views.
            // They cannot ACK or poison another owner; stop the one retained
            // session explicitly while the outer device retains its DMA.
            channel.session.stop();
            if (channel.last_rpc) |rpc| self.log("NVIDIA gsp-runtime: failed={s} last-rpc={x} sequence={d} result={x} receipt={s}",
                .{@errorName(err), rpc.function, rpc.sequence, rpc.result, if (channel.session.pending != null) @as([]const u8, "retained") else "none"});
            // The failed exchange retains its CPU receive buffer and exact
            // request. Observe those bytes without ACK, MMIO or a new query;
            // firmware success alone does not authorize a malformed receipt.
            if (channel.pending) |dispatch| if (dispatch.response) {
                self.log("NVIDIA gsp-receipt: function={x} sequence={d} request-bytes={d} response-bytes={d} retained=yes",
                    .{dispatch.record.rpc.function, dispatch.record.rpc.sequence, channel.request.len, dispatch.record.payload.len});
                self.logRpcBytes("request", channel.request);
                self.logRpcBytes("response", dispatch.record.payload);
            };
            if (self.post.self_address != 0 and self.post.state != .complete)
                self.log("NVIDIA gsp-postinit: failed={s} command={x} status={x} replies={d}",
                    .{@errorName(err), @intFromEnum(self.post.command), self.post.last_status orelse exchange.message.pending, self.post.replies});
        }
        if (self.graph) |*graph| {
            if (graph.state != .finished) graph.base.exchange.session.rm_names.retain(graph.reservation) catch {};
            self.log("NVIDIA gsp-rm: failed={s} state={s} client={x} rejection={?}",
                .{@errorName(err), @tagName(graph.state), graph.reservation.client, self.rm_rejection});
            if (graph.address_space) |*space| if (space.plan.external_vaspace) {
                const vm = &space.host_vm;
                self.log("NVIDIA gsp-host-mmu: control={s} reply={?} root={x} attached={} phase={s} offset={d} tlb={s} failure={?} retained=yes",
                    .{ if (space.host_control) |op| @tagName(op) else "none", space.rejected,
                        if (vm.root) |root| root.dma else 0, vm.attached,
                        if (vm.work) |work| @tagName(work.phase) else "none",
                        if (vm.work) |work| work.offset else 0,
                        if (vm.work) |work| if (work.invalidate) |op| @tagName(op.phase) else "none" else "none", vm.failure });
                const pages = &space.host_storage;
                self.log("NVIDIA gsp-host-pages: deferred={d} release={s} status={d} backing-step={s} failure={?}",
                    .{pages.deferred_pages, @tagName(pages.last_operation), pages.last_status, pages.last_backing_step, pages.failure});
            };
            if (graph.control_buffer) |*owner|
                self.log("NVIDIA gsp-control: failed={s} operation={s} reply={?} registered={} allocated={} mapped={} retained={}",
                    .{@errorName(err), if (owner.caps_active) "memory-caps" else if (owner.operation) |operation| @tagName(operation) else "none", owner.last_status,
                        owner.registered, owner.allocated, owner.mapped, owner.backing.retained});
        }
        if (self.native_copy.self_address != 0)
            self.log("NVIDIA gsp-native-ce: failed={s} phase={s} rm-engine={d} context={} channel={} storage={} retained=yes",
                .{@errorName(err), @tagName(self.native_copy.phase), self.native_copy.rm_engine,
                    self.native_copy.context != null, self.native_copy.channel != null, self.native_copy.storage != null});
        for (&self.contexts) |*slot| if (slot.owner) |owner| self.logContextDiscovery(owner);
        if (self.display_engine_owner) |*owner| self.log("NVIDIA gsp-display-engine: failed={s} root={x} operation={s} status={?} confirmed={} possible={} boot=retained",
            .{@errorName(err),owner.binding.root,if (owner.operation) |op| @tagName(op) else "none",owner.last_status,owner.live,owner.allocation_possible});
        if (self.mode_control_owner) |*owner| self.log("NVIDIA gsp-mode-query: failed={s} handle={x} operation={s} status={?} clock-limit-hz={d} control-live={} resources=retained",
            .{@errorName(err),owner.binding.control,if (owner.operation) |op| @tagName(op) else "none",owner.last_status,owner.source_clock_hz,owner.live});
        for (&self.display_channels) |*slot| if (slot.*) |*owner| self.log("NVIDIA gsp-display-channel: failed={s} handle={x} class={x} index={d} rm-live={} possible={} control={x} state={x} storage-held={}",
            .{@errorName(err),owner.config.handle,display_channel.wire.classFor(owner.config.root,owner.config.kind),owner.config.index,owner.live,owner.allocation_possible,
                owner.last_control,owner.last_state,owner.backing.retained});
        if (self.display_resources_slot.owner) |owner| self.log("NVIDIA gsp-display-table: failed={s} entries={d} revision={d} published={d} upload-held={} storage=retained",
            .{@errorName(err),owner.table.count,owner.table.revision,owner.table.uploaded_revision,self.display_upload_job != null});
        if (self.display_work) |*work| self.log("NVIDIA gsp-display-push: failed={s} channel={x} phase={s} point={d} notifier={x} storage=retained",
            .{@errorName(err),work.core.handle.handle,@tagName(work.core.phase),if(work.core.ticket)|ticket|ticket.point else 0,if(work.core.notifier.result)|result|result.word else 0});
        if (self.display_work) |*work| if (work.window) |*window| self.log("NVIDIA gsp-display-image: failed={s} window={d} phase={s} point={d} image={?x} previous={?x} storage=retained",
            .{@errorName(err),window.config.route.?.window,@tagName(window.phase),if(window.ticket)|ticket|ticket.point else 0,
                if(window.config.scanout)|image|@as(?u32,image.dma) else null,if(work.detach)|previous|@as(?u32,previous.image.dma) else null});
        for (&self.display_flips) |*slot| if (slot.*) |*work| self.log("NVIDIA gsp-flip: failed={s} head={d} sequence={d} phase={s} render={d} window={d} visible={} old-released={} resources=retained",
            .{@errorName(err),work.receipt.head,work.receipt.sequence,@tagName(work.window.phase),work.receipt.render_point,
                if(work.window.ticket)|ticket|ticket.point else 0,work.receipt.begun_observed_ns != 0,work.receipt.previous_released_ns != 0});
        if (self.display_work) |*work| if (work.position) |*position| self.log("NVIDIA gsp-display-position: failed={s} channel={x} phase={s} point={d} storage=retained",
            .{@errorName(err),position.handle.handle,@tagName(position.phase),if(position.ticket)|ticket|ticket.point else 0});
        if (self.initial_image) |*work| self.log("NVIDIA gsp-initial-image: failed={s} submitted={} point={d} source-held={} storage=retained",
            .{@errorName(err),work.operation.submitted,if(work.operation.ticket)|ticket|ticket.point else 0,work.operation.gpu.lease.id != 0});
        if (self.display_work) |*work| if (work.link) |*link| self.log("NVIDIA gsp-link: failed={s} display={x} phase={s} operation={s} replies={d} receipt={d} status={?} rpc={} storage=retained",
            .{@errorName(err),link.plan.mode.signal.display_id,@tagName(link.phase),@tagName(link.operation),link.acknowledged,link.last_receipt,link.last_status,link.rpc_error});
    }
    fn recordFault(self: *Owner, value: diagnostics.Record) !void {
        var record = value;
        record.epoch = self.epoch; record.time_ns = self.last_clock;
        // RM allocation cid and opaque submit tokens are not hardware CHIDs.
        // Engine/runlist and GPU-VA observations identify candidates only.
        for (&self.fifos) |*slot| if (slot.owner) |owner| {
            if (owner.config_stamp == null or owner.config.context.epoch != self.epoch) continue;
            self.log("NVIDIA gsp-fifo-failure: channel={x} state={s} op={s} rejection={?x} host={s} last-status={?x} hw-chid={d} runlist={d} bound={} token={?x}",
                .{owner.config.handle, @tagName(owner.state), if (owner.operation) |op| @tagName(op) else "none",
                    owner.rejected, if (owner.host_rejected) |err| @errorName(err) else "none", owner.last_status,
                    owner.config.hardware_channel, owner.config.runlist, owner.bound, owner.work_submit_token});
            if (!owner.live) continue;
            const parent = owner.parent orelse continue;
            const selected = parent.selected orelse continue;
            if (record.runlist) |runlist| if (runlist != selected.data[3]) continue;
            if (record.nv_engine) |nv_engine| if (nv_engine != (execution_context.wire.nvEngine(parent.rm_engine) catch continue)) continue;
            record.candidate_channels += 1;
            if (record.candidate_channels == 1) {
                record.candidate_rm_handle = owner.config.handle; record.candidate_rm_cid = owner.cid;
            } else { record.candidate_rm_handle = 0; record.candidate_rm_cid = 0; }
        };
        if (self.copy_job) |work| {
            record.active_fence = work.job.fence;
            if (work.ticket) |ticket| record.copy_point = ticket.point;
            if (record.fault_address) |va| {
                if (work.transfer) |transfer| {
                    // Presentation has no fabricated target queue reference.
                    // Use the submitted 2D extents, including each row pitch.
                    for ([_]u64{transfer.source, transfer.target}, 0..) |base, i| {
                        const bytes = transfer.span(i == 1) catch continue;
                        const matches = va >= base and va - base < bytes;
                        if (i == 0) record.source_address_match = matches else record.target_address_match = matches;
                    }
                } else for (work.addresses, [_]u64{work.job.source_offset, work.job.target_offset}, 0..) |mapped, offset, i| {
                    const span = mapped orelse continue;
                    if (offset > span.bytes or work.job.byte_length > span.bytes - offset or span.address > std.math.maxInt(u64) - offset) continue;
                    const base = span.address + offset;
                    const matches = va >= base and va - base < work.job.byte_length;
                    if (i == 0) record.source_address_match = matches else record.target_address_match = matches;
                }
            }
        }
        if (self.queued_native) |work| record.active_fence = work.job.fence;
        if (self.queued_render) |work| {
            record.active_fence = work.job.fence;
            record.render_phase = switch (work.phase) {
                .retain => .resources, .prepare => .admission,
                .upload, .upload_wait => .packet_upload, .draw, .draw_wait => .execution, .done => .none,
            };
        }
        if (self.graphics_upload) |*work| {
            record.render_phase = if (work.operation.kind == .programs) .programs_upload else .packet_upload;
            if (work.operation.ticket) |ticket| record.copy_point = ticket.point;
        }
        if (self.graphics_work) |*work| {
            record.render_phase = .execution;
            if (work.ticket) |ticket| record.graphics_point = ticket.point;
            if (self.fifos[work.channel_handle.slot].owner) |owner| record.graphics_class = owner.config.object_class;
            if (record.fault_address) |va| switch (work.command) {
                .draw => |binding| {
                    const dst = binding.draw.target;
                    record.target_address_match = va >= dst.address and va-dst.address < dst.bytes;
                    if (binding.draw.source) |src| record.source_address_match = va >= src.address and va-src.address < src.bytes;
                },
                else => {},
            };
        }
        if (record.render_phase != .none) {
            if (self.graphics_cache.programs.info()) |programs| {
                record.programs_address = programs.address;
                if (record.fault_address) |va| record.programs_address_match = va >= programs.address and va-programs.address < render.shader_bytes;
            }
            if (self.graphics_cache.packet.info()) |packet| {
                record.packet_address = packet.address;
                if (record.fault_address) |va| record.packet_address_match = va >= packet.address and va-packet.address < packet.bytes;
            }
        }
        if (self.display_upload_job) |*work| {
            if (work.operation.ticket) |ticket| record.copy_point = ticket.point;
            if (record.fault_address) |va| {
                if (work.operation.source_stamp) |src| record.source_address_match = va >= src.address and va - src.address < work.operation.payloadBytes();
                if (work.operation.target_stamp) |dst| record.target_address_match = va >= dst.address and va - dst.address < work.operation.payloadBytes();
            }
            // This private transfer has no common-queue fence to fabricate.
        }
        if (self.initial_image) |*work| {
            if (work.operation.ticket) |ticket| record.copy_point = ticket.point;
            if (record.fault_address) |va| if (work.operation.transfer() catch null) |transfer| {
                for ([_]u64{transfer.source, transfer.target}, 0..) |base, i| {
                    const bytes = transfer.span(i == 1) catch continue;
                    const matches = va >= base and va - base < bytes;
                    if (i == 0) record.source_address_match = matches else record.target_address_match = matches;
                }
            };
        }
        const kept = try self.faults.append(record);
        self.log("NVIDIA gsp-fault: serial={d} epoch={d} source={s} kind={s} operation={s} object={x} code={x} fatal={}",
            .{kept.serial,kept.epoch,@tagName(kept.source),@tagName(kept.kind),@tagName(kept.operation),kept.rm_handle,kept.code,kept.fatal});
        self.log("NVIDIA gsp-fault: hardware-chid={?} runlist={?} nv-engine={?} candidates={d} rm-handle={x} rm-cid={d} exact-chid=no",
            .{kept.hardware_channel,kept.runlist,kept.nv_engine,kept.candidate_channels,kept.candidate_rm_handle,kept.candidate_rm_cid});
        self.log("NVIDIA gsp-fault: address={?} type={x} source-span={} target-span={} fence={d}:{d} copy-point={d} callback={}",
            .{kept.fault_address,kept.fault_type,kept.source_address_match,kept.target_address_match,kept.active_fence.timeline,kept.active_fence.point,kept.copy_point,kept.callback_needed});
        if (kept.render_phase != .none or kept.shader != .none) {
            self.log("NVIDIA render-fault: phase={s} shader={s} class={x} gr-point={d} completed={d} resources-retained={}",
                .{@tagName(kept.render_phase),@tagName(kept.shader),kept.graphics_class,kept.graphics_point,self.graphics_completed,self.graphics_cache.borrowed});
            self.log("NVIDIA render-fault: programs={x} packet={x} programs-span={} packet-span={} attribution=candidate-only",
                .{kept.programs_address,kept.packet_address,kept.programs_address_match,kept.packet_address_match});
            if (self.graphics_work) |*work| if (self.device) |port| {
                const audit = port.submission;
                self.log("NVIDIA render-submit: submitted={} ticket={?} deadline={d} worker-now={d} producer={s} point={d} stage={s} observed={d} failure={s}",
                    .{work.submitted, if (work.ticket) |ticket| ticket.point else null, work.deadline, self.snapshot.last_poll_ns,
                        @tagName(audit.producer), audit.point, @tagName(audit.stage), audit.observed_ns,
                        if (audit.failure) |err| @errorName(err) else "none"});
            };
            if (self.graphics_upload) |*work| if (self.device) |port| {
                const upload = &work.operation;
                const audit = port.submission;
                self.log("NVIDIA render-upload: kind={s} submitted={} ticket={?} deadline={d} worker-now={d} port-now={d} producer={s} point={d} stage={s} failure={s}",
                    .{@tagName(upload.kind), upload.submitted, if (upload.ticket) |ticket| ticket.point else null,
                        upload.deadline, self.snapshot.last_poll_ns, port.last_clock, @tagName(audit.producer), audit.point,
                        @tagName(audit.stage), if (audit.failure) |err| @errorName(err) else "none"});
                self.log("NVIDIA render-upload-owner: RM={s} pending={} sequence={} power={} display={} context={} fifo={} VA={} native={} buffer={} output={}",
                    .{if (self.channel) |main| @tagName(main.phase) else "none", if (self.channel) |main| main.pending != null else false,
                        self.sequence.self_address != 0, self.power_active, self.display_work != null,
                        self.context_active != null, self.fifo_active != null, self.virtuals.active_range != null,
                        self.native_active != null, self.buffer_active != null, self.outputs.active()});
            };
        }
        if (kept.text_bytes != 0) self.logBytes("fault-text", @truncate(kept.code), kept.text[0..kept.text_bytes]);
        if (kept.fatal and self.faults.first_fatal != null and self.faults.first_fatal.?.serial == kept.serial) self.logExecutionRings();
    }
    noinline fn logExecutionRings(self: *Owner) void {
        for (&self.fifos) |*slot| if (slot.owner) |owner| {
            if (!owner.live or owner.config_stamp == null or owner.config.context.epoch != self.epoch) continue;
            owner.ring.logDiagnostic(&self.ctx.?, owner.config.handle, owner.cid, owner.work_submit_token orelse 0);
        };
    }
    pub fn renderRejection(self: *Owner, err: anyerror) !void {
        var record = diagnostics.host(.render,err,false);
        record.kind = .graphics_command;
        try self.recordFault(record);
    }
    pub fn nativeRejection(self: *Owner, err: anyerror) !void {
        try self.recordFault(diagnostics.host(.submit,err,false));
    }
    fn rejection(self: *Owner, operation: diagnostics.Operation, handle: u32, status: ?u32, host: ?anyerror) !void {
        if (status) |code| try self.recordFault(.{ .source = .rm, .kind = diagnostics.rmKind(code), .operation = operation, .rm_handle = handle, .code = code })
        else if (host) |err| { var record = diagnostics.host(operation, err, false); record.rm_handle = handle; try self.recordFault(record); }
    }
    fn rmFailure(self: *Owner, operation: diagnostics.Operation, handle: u32, status: ?u32) void {
        if (status) |code| if (code != 0) {
            self.recordFault(.{ .source = .rm, .kind = diagnostics.rmKind(code), .operation = operation, .rm_handle = handle, .code = code, .fatal = true }) catch {};
        };
    }
    fn hostRejection(self: *Owner, operation: diagnostics.Operation, err: anyerror) void {
        if (self.failure != null or self.self_address != @intFromPtr(self)) return;
        if (err == error.Memory or err == error.Exhausted or err == error.OutOfMemory or err == error.Budget) {
            self.recordFault(diagnostics.host(operation, err, false)) catch {};
            if (operation == .native_buffer) {
                self.residency_rejections +|= 1;
                // Pressure retries must not flood the serial path with a full
                // owner inventory. Keep every journal entry, sample details.
                if (self.residency_rejections & (self.residency_rejections - 1) == 0) self.logResidency();
            }
        }
    }
    pub fn reportIrq(self: *Owner, endpoint: *const @import("gsp_irq.zig").Owner) void {
        if (self.self_address != @intFromPtr(self) or self.failure != null) return;
        if (endpoint.display.enabled and endpoint.display.epoch == self.epoch) self.head_events = &endpoint.display;
        const code = @atomicLoad(u32, &endpoint.fault, .acquire);
        if (code == 0) return;
        self.recordFault(.{ .source = .irq, .kind = .interrupt, .operation = .interrupt, .fatal = true, .code = code,
            .irq = endpoint.irq, .irq_raw = @atomicLoad(u32, &endpoint.last_raw, .acquire),
            .irq_mask = @atomicLoad(u32, &endpoint.last_mask, .acquire), .irq_received = @atomicLoad(u64, &endpoint.interrupts, .acquire),
            .irq_messages = @atomicLoad(u64, &endpoint.messages, .acquire) }) catch {};
    }
    pub fn activeChannel(self: *Owner) ?*exchange.Exchange {
        if (self.power_active) if (self.power_owner) |*owner| if (owner.active) |*active| return active;
        if (self.mode_control_active) if (self.mode_control_owner) |*owner| return &owner.exchange;
        if (self.display_channel_active) |index| if (self.display_channels[index]) |*owner| return &owner.exchange;
        if (self.display_engine_active) if (self.display_engine_owner) |*owner| return &owner.exchange;
        if (self.fifo_active) |index| if (self.fifos[index].owner) |owner| return owner.channel();
        if (self.context_active) |index| if (self.contexts[index].owner) |owner| return &owner.exchange;
        if (self.native_active) |index| if (self.native_buffers.items()[index].owner) |owner| return &owner.exchange;
        if (self.buffer_active) |index| if (self.buffers.items()[index].owner) |owner| return &owner.exchange;
        if (self.virtuals.active()) |owner| return &owner.exchange;
        if (self.outputs.channel()) |channel| return &channel.exchange;
        if (self.graph) |*graph| if (graph.channel()) |channel| return channel;
        return if (self.channel) |*channel| channel else null;
    }
    pub fn nativeObject(self: *Owner) ?display.Object {
        if (self.hasDisplayFlips()) return null;
        return self.nativeObjectForDisplay();
    }
    fn nativeObjectForDisplay(self: *Owner) ?display.Object {
        if (self.self_address != @intFromPtr(self) or self.failure != null or self.graph == null or
            self.display_upload_job != null or self.display_work != null or self.cursor_point != null or self.cursor_upload != null or self.audio_work != null or self.monitor_work != null or self.sor_work != null or
            self.graph.?.self_address != @intFromPtr(&self.graph.?) or self.graph.?.state != .loaned or
            self.display_object == null or self.channel == null or self.activeChannel() != &self.channel.? or
            self.channel.?.session.state != .active) return null;
        return self.display_object;
    }
    pub fn nativeOutputs(self: *Owner) ?*const outputs.Snapshot {
        _ = self.now() catch return null;
        if (self.frame_ready != null or self.copy_job != null) return null;
        if (self.nativeObject() == null) return null;
        return self.outputs.snapshot();
    }
    pub fn nativeMemory(self: *Owner) ?*const inventory.Summary {
        _ = self.now() catch return null;
        return self.memory_inventory.snapshot();
    }
    pub fn residencySnapshot(self: *const Owner) !@import("gsp_residency.zig").Snapshot {
        return @import("gsp_residency.zig").read(self);
    }
    fn logResidency(self: *Owner) void {
        const data = self.residencySnapshot() catch {
            self.log("NVIDIA residency: unavailable owner-inconsistent resources=retained", .{});
            return;
        };
        self.log("NVIDIA residency: epoch={d} firmware-known={} physical={d} firmware={d} boot-union={d} rm-hint={d}",
            .{data.epoch,data.firmware_capture_known,data.physical_bytes,data.firmware_reserved_bytes,data.boot_retained_bytes,data.rm_reserved_hint_bytes});
        self.log("NVIDIA residency: native-slots={d} reserved={d} physical-acked={d} mapped={d} retiring={d} uncertain={d}",
            .{data.native_slots,data.native_reserved_bytes,data.native_physical_bytes,data.native_mapped_bytes,data.native_retiring_bytes,data.native_uncertain_bytes});
        self.log("NVIDIA residency: control={d} scanout={d} render-cache={d} mapping-reserved={d} mapping-cache={d} evicting={d} evictions={d} subsets=yes",
            .{data.control_reserved_bytes,data.scanout_reserved_bytes,data.render_cache_bytes,data.mapping_reserved_bytes,data.mapping_cache_bytes,data.mapping_evicting_bytes,data.mapping_evictions});
        self.log("NVIDIA residency: budget-configured={} limit={d} progress-margin={d} last-admission-charge={d} denials={d}",
            .{self.memory_admission.configured,self.memory_admission.limit_bytes,self.memory_admission.progress_bytes,self.memory_admission.charged_bytes,self.memory_admission.denials});
        if (self.memory_admission.requested_limit_bytes != 0) self.log("NVIDIA residency: configured-headless-limit={d} placement-guarantee=no", .{
            self.memory_admission.requested_limit_bytes });
        self.log("NVIDIA residency: placement=host-application,RM-private host-extents={d} host-bytes={d} largest-free-extent=unknown fragmentation=unmeasured retained-is-not-leak=yes",
            .{self.user_vram.count, self.user_vram.bytes});
        self.log("NVIDIA scheduling: held={d}/{d} high-water={d} slices={d} copy-limit={d} render-pixels={d} cursor=between-physical-slices",
            .{self.work_schedule.count(),scheduling.capacity,self.work_schedule.high_water,self.work_schedule.slices,
                self.work_schedule.copy_limit,self.work_schedule.render_limit});
    }
    pub fn nativeAddressSpace(self: *Owner) ?*const @import("gsp_vaspace.zig").Info {
        _ = self.now() catch return null;
        if (self.nativeObjectForDisplay() == null) return null;
        const owner = if (self.graph.?.address_space) |*value| value else return null;
        if (owner.self_address != @intFromPtr(owner) or owner.state != .handed_off or owner.exchange.session.state != .active) return null;
        return if (owner.info) |*info| info else null;
    }
    pub fn nativeMemoryCapabilities(self: *Owner) ?@import("gsp_memory_caps.zig").Info {
        const space = self.nativeAddressSpace() orelse return null;
        const owner = if (self.graph.?.control_buffer) |*value| value else return null;
        if (owner.adapter != self.adapter_id or !std.meta.eql(owner.binding.space, space.*)) return null;
        return owner.memoryCapabilities();
    }
    pub fn nativeControlBuffer(self: *Owner) ?@import("gsp_control_buffer.zig").Info {
        const space = self.nativeAddressSpace() orelse return null;
        const owner = if (self.graph.?.control_buffer) |*value| value else return null;
        if (owner.adapter != self.adapter_id or owner.backing.adapter != self.adapter_id or
            owner.backing.epoch != self.epoch or !std.meta.eql(owner.binding.space, space.*)) return null;
        return owner.info();
    }
    /// Reserve the native display root independently of output discovery.
    /// No display instance replacement, DMA channel or native handoff yet.
    pub fn createDisplayEngine(self: *Owner, deadline: u64) !DisplayEngineHandle {
        _ = try self.now();
        if (self.display_engine_owner != null or self.graph_closing or self.copyBusy() or self.sequence.self_address != 0) return error.Busy;
        _ = self.nativeObject() orelse return error.State;
        const internal = self.static_info orelse return error.State;
        const held = self.reservation orelse return error.State;
        _ = try held.binding(.metadata);
        const captured = held.display orelse return error.Stale;
        if (captured.chip == null or !@import("generation.zig").ga102Hal(captured.chip.?.id)) return error.Unsupported;
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        var token = try self.channel.?.handoff(deadline);
        const owner = display_engine.Owner.init(&token, self.graph.?.reservation, self.graph.?.base.plan.handles.device, internal.client, internal.subdevice, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        self.display_engine_owner = owner; self.display_engine_active = true;
        return .{ .epoch = self.epoch, .root = owner.binding.root };
    }
    fn findDisplayEngine(self: *Owner, handle: DisplayEngineHandle) !*display_engine.Owner {
        _ = try self.now();
        const owner = if (self.display_engine_owner) |*value| value else return error.Stale;
        if (handle.epoch != self.epoch or handle.root != owner.binding.root or handle.root == 0) return error.Stale;
        return owner;
    }
    pub fn displayEngineStatus(self: *Owner, handle: DisplayEngineHandle) !DisplayEngineStatus {
        const owner = try self.findDisplayEngine(handle);
        return .{ .state = owner.state, .info = owner.info(), .rejected = owner.rejected, .unavailable = owner.unavailable };
    }
    pub fn retireDisplayEngine(self: *Owner, handle: DisplayEngineHandle, deadline: u64) !void {
        const owner = try self.findDisplayEngine(handle);
        if (self.mode_control_owner != null) return error.Busy;
        if (self.display_engine_active or self.copyBusy() or self.sequence.self_address != 0 or self.nativeObject() == null or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        var token = try self.channel.?.handoff(deadline);
        owner.beginDestroy(&token, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        self.display_engine_active = true;
    }
    pub fn validateModeQuery(self: *Owner, root: DisplayEngineHandle, plan: boot_mode.Plan) !void {
        const expected = try self.displayColorModePlan(root, plan.window, plan.receiver_mode_id, plan.color, plan.color_pipeline);
        if (!std.meta.eql(expected, plan)) return error.Stale;
        try display_link.validate(expected, self.display_object.?, self.outputs.snapshot().?);
    }
    pub fn modeTopology(self: *const Owner, candidate: boot_mode.Plan) !mode_control.Topology {
        var result = mode_control.Topology.single(candidate);
        for (&self.display_images) |*entry| if (entry.*) |*active| {
            const current = if (active.boot_mode) |*value| value else return error.Unsupported;
            if (current.head == candidate.head and current.window == candidate.window) continue;
            try result.append(current.*);
        };
        return result;
    }
    pub fn validateModeTopology(self: *Owner, root: DisplayEngineHandle, plan: boot_mode.Plan, topology: *const mode_control.Topology) !void {
        try self.validateModeQuery(root, plan);
        // A completed query is valid only for this complete active set.
        // Ordinary flips change images/receipts, never the bandwidth inputs.
        // Compare the resident entries directly: materializing another eight
        // plans and using array-value equality consumes the 64-KB task stack.
        if (topology.count == 0 or topology.count > topology.plans.len or
            topology.plans[0] == null or !std.meta.eql(topology.plans[0].?, plan)) return error.Stale;
        var count: usize = 1;
        for (&self.display_images) |*entry| if (entry.*) |*active| {
            const current = if (active.boot_mode) |*value| value else return error.Unsupported;
            if (current.head == plan.head and current.window == plan.window) continue;
            try topology.validateNext(count, current);
            if (count >= topology.count or topology.plans[count] == null or
                !std.meta.eql(topology.plans[count].?, current.*)) return error.Stale;
            count += 1;
        };
        if (count != topology.count) return error.Stale;
        for (topology.plans[count..]) |*entry| if (entry.* != null) return error.Stale;
    }
    pub fn createModeControl(self: *Owner, root: DisplayEngineHandle, plan: boot_mode.Plan, deadline: u64) !ModeControlHandle {
        _ = try self.now();
        if (self.mode_control_owner != null or self.graph_closing or self.copyBusy() or self.sequence.self_address != 0) return error.Busy;
        const object = self.nativeObject() orelse return error.Busy;
        try self.validateModeQuery(root, plan);
        const topology = try self.modeTopology(plan);
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        var token = try self.channel.?.handoff(deadline);
        const owner = mode_control.Owner.initTopology(&token, self.graph.?.reservation, self.graph.?.base.plan.handles.device, object.display, plan, topology, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        self.mode_control_owner = owner; self.mode_control_root = root; self.mode_control_active = true;
        return .{ .epoch = self.epoch, .handle = owner.binding.control };
    }
    fn findModeControl(self: *Owner, handle: ModeControlHandle) !*mode_control.Owner {
        _ = try self.now();
        const owner = if (self.mode_control_owner) |*value| value else return error.Stale;
        if (handle.epoch != self.epoch or handle.handle == 0 or handle.handle != owner.binding.control) return error.Stale;
        return owner;
    }
    pub fn modeControlStatus(self: *Owner, handle: ModeControlHandle) !ModeControlStatus {
        const owner = try self.findModeControl(handle);
        // Cancellation has no fresh receiver timing to validate. Preserve
        // the query identity/state while info() withholds its obsolete proof.
        if (!owner.obsolete) try self.validateModeTopology(self.mode_control_root.?, owner.mode, &owner.topology);
        return .{ .state = owner.state, .info = owner.info(), .rejected = owner.rejected, .unavailable = owner.unavailable };
    }
    pub fn cancelModeQuery(self: *Owner) !void {
        if (!self.display_paused) return error.State;
        return self.invalidateModeQuery();
    }
    pub fn cancelOutputModeQuery(self: *Owner, window: u32) !void {
        if (!self.outputPaused(window)) return error.State;
        if (self.mode_control_owner) |*owner| if (owner.mode.window != window) return;
        return self.invalidateModeQuery();
    }
    fn invalidateModeQuery(self: *Owner) !void {
        if (self.mode_control_owner) |*owner| {
            if (!owner.live or (owner.state != .querying and owner.state != .ready and owner.state != .handed_off)) return error.State;
            owner.obsolete = true;
        }
    }
    pub fn queryDisplayMode(self: *Owner, handle: ModeControlHandle, plan: boot_mode.Plan, deadline: u64) !void {
        const owner = try self.findModeControl(handle);
        if (self.copyBusy() or self.sequence.self_address != 0 or self.nativeObject() == null or self.channel.?.phase != .idle or
            self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        var intent = plan; intent.signal.hdmi_dsc = null;
        try self.validateModeQuery(self.mode_control_root.?, intent);
        const topology = try self.modeTopology(intent);
        try self.channel.?.guard(deadline);
        var token = try self.channel.?.handoff(deadline);
        owner.beginQueryTopology(&token, intent, topology, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        self.mode_control_active = true;
    }
    pub fn retireModeControl(self: *Owner, handle: ModeControlHandle, deadline: u64) !void {
        const owner = try self.findModeControl(handle);
        if (self.copyBusy() or self.sequence.self_address != 0 or self.nativeObject() == null or self.channel.?.phase != .idle or
            self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        var token = try self.channel.?.handoff(deadline);
        owner.beginDestroy(&token, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        self.mode_control_active = true;
    }
    pub fn attachDisplayInstance(self: *Owner, handle: DisplayEngineHandle, source: BufferHandle, deadline: u64) !void {
        const owner = try self.findDisplayEngine(handle);
        if (self.display_engine_active or self.copyBusy() or self.sequence.self_address != 0 or self.nativeObject() == null or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        const backing = try self.findNativeBuffer(source);
        if (backing.adapter != self.adapter_id) return error.Stale;
        try self.channel.?.guard(deadline);
        var token = try self.channel.?.handoff(deadline);
        owner.attachInstance(backing, &token, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; };
            if (err == error.Descriptor or err == error.Retained) self.stop(err);
            return err;
        };
        self.display_engine_active = true;
    }
    pub fn createDisplayChannel(self: *Owner, handle: DisplayEngineHandle, kind: display_channel.wire.Kind, index: u32, deadline: u64) !DisplayChannelHandle {
        const parent = try self.findDisplayEngine(handle);
        if (self.copyBusy() or self.sequence.self_address != 0 or self.graph_closing or self.nativeObject() == null or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        const slot = try display_channel.wire.slot(kind, index);
        if (self.display_channels[slot] != null) return error.Busy;
        if (kind != .core) {
            const core_channel = if (self.display_channels[0]) |*value| value else return error.State;
            if (core_channel.info() == null) return error.State;
        }
        if (kind == .immediate) {
            const window_channel = if (self.display_channels[1 + index]) |*value| value else return error.State;
            if (window_channel.info() == null or window_channel.parent != parent) return error.State;
        }
        try self.channel.?.guard(deadline);
        var token = try self.channel.?.handoff(deadline);
        const owner = display_channel.Owner.init(&token, self.ctx.?, self.adapter_id, parent, kind, index, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        parent.channels_started = true;
        self.display_channels[slot] = owner; self.display_channel_active = @intCast(slot);
        return .{ .epoch = self.epoch, .handle = owner.config.handle, .slot = @intCast(slot) };
    }
    fn findDisplayChannel(self: *Owner, handle: DisplayChannelHandle) !*display_channel.Owner {
        _ = try self.now();
        if (handle.epoch != self.epoch or handle.slot >= self.display_channels.len or handle.handle == 0) return error.Stale;
        const owner = if (self.display_channels[handle.slot]) |*value| value else return error.Stale;
        if (owner.config.handle != handle.handle) return error.Stale;
        return owner;
    }
    pub fn displayChannelStatus(self: *Owner, handle: DisplayChannelHandle) !DisplayChannelStatus {
        const owner = try self.findDisplayChannel(handle);
        return .{ .state = owner.state, .info = owner.info(), .rejected = owner.rejected, .host_rejected = owner.host_rejected,
            .initialized = owner.ring.initialized, .completed = owner.ring.completed };
    }
    pub fn retireDisplayChannel(self: *Owner, handle: DisplayChannelHandle, deadline: u64) !void {
        const owner = try self.findDisplayChannel(handle);
        if (self.presentation != null and owner.config.kind != .cursor) return error.Busy;
        if (owner.config.kind == .cursor) if (self.cursor_storage) |storage| {
            if (storage.head == owner.config.index and storage.active != null) return error.Busy;
        };
        if (self.copyBusy() or self.sequence.self_address != 0 or self.nativeObject() == null or self.channel.?.phase != .idle or
            self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        var token = try self.channel.?.handoff(deadline);
        owner.beginDestroy(&token, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        self.display_channel_active = handle.slot;
    }
    /// Initial population or a fresh live image entry. Live updates never
    /// rewrite an active DMA descriptor and require drained display methods.
    pub fn bindDisplayStorage(self: *Owner, handle: DisplayEngineHandle, kind: display_channel.wire.Kind, index: u32, source: BufferHandle) !u32 {
        if (kind == .immediate or kind == .cursor) return error.Unsupported; // Immediate channels have no RAMHT DMA contexts.
        const parent = try self.mutableDisplayTable(handle);
        const config = parent.info() orelse return error.State;
        const slot = try display_channel.wire.slot(kind, index);
        if ((kind == .core and !config.core) or (kind == .window and (!config.window or config.hardware.windows & (@as(u32, 1) << @intCast(index)) == 0))) return error.Unsupported;
        const storage = try self.findNativeBuffer(source);
        if (parent.channels_started and (kind != .window or !(storage.info() orelse return error.Stale).surface.scanout())) return error.Unsupported;
        const owner = try self.ensureDisplayResources(parent);
        return owner.bindNative(@intCast(slot), storage) catch |err| {
            if (err == error.Descriptor or err == error.Retained) self.stop(err);
            return err;
        };
    }
    pub fn bindDirectImage(self: *Owner, root: DisplayEngineHandle, window: DisplayChannelHandle, reference: r4os.abi.GfxBufferReference) !u32 {
        if (!self.direct_step or self.direct_work == null or self.presentation == null or !std.meta.eql(self.presentation.?.window, window)) return error.State;
        const parent = try self.mutableDisplayTable(root);
        const resources = try self.ensureDisplayResources(parent);
        for (self.native_buffers.items()) |*slot| if (slot.owner) |source| if (source.scanoutInfo(reference)) |value| {
            if (value.surface.descriptor.width != self.presentation.?.surface.descriptor.width or
                value.surface.descriptor.height != self.presentation.?.surface.descriptor.height) return error.Unsupported;
            return resources.bindScanout(window.slot, source, reference);
        };
        return error.Unsupported;
    }
    pub fn bindBootConsole(self: *Owner, handle: DisplayEngineHandle, index: u32, source: *@import("boot_console.zig").Owner) !u32 {
        if (self.presentation != null or self.copy_backend != null or source.lease != self.memory_inventory.lease) return error.State;
        const parent = try self.mutableDisplayTable(handle);
        const info = parent.info() orelse return error.State;
        if (parent.channels_started or index >= 8 or info.hardware.windows & (@as(u32, 1) << @intCast(index)) == 0) return error.Unsupported;
        return (try self.ensureDisplayResources(parent)).bindConsole(index + 1, source);
    }
    pub fn createDisplayNotifier(self: *Owner, handle: DisplayEngineHandle, kind: display_channel.wire.Kind, index: u32) !u32 {
        if (kind == .immediate) return error.Unsupported; // Completion belongs to the coupled Window/Core.
        const root = try self.findDisplayEngine(handle);
        const parent = if (root.channels_started and kind == .window) try self.mutableDisplayTable(handle) else try self.idleDisplayTable(handle);
        const config = parent.info() orelse return error.State;
        const slot = try display_channel.wire.slot(kind, index);
        if ((kind == .core and !config.core) or (kind == .window and (!config.window or config.hardware.windows & (@as(u32, 1) << @intCast(index)) == 0))) return error.Unsupported;
        if (parent.channels_started and (index >= 8 or self.output_claims[index] == null or
            self.display_channels[slot] != null or self.display_images[index] != null)) return error.Busy;
        const owner = try self.ensureDisplayResources(parent);
        return owner.createNotifier(&self.ctx.?, @intCast(slot)) catch |err| {
            if (err == error.Descriptor or err == error.Retained) self.stop(err); return err;
        };
    }
    fn idleDisplayTable(self: *Owner, handle: DisplayEngineHandle) !*display_engine.Owner {
        const parent = try self.findDisplayEngine(handle);
        if (self.copyBusy() or self.graph_closing or self.sequence.self_address != 0 or self.nativeObject() == null or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        const config = parent.info() orelse return error.State;
        if (!config.instance_bound) return error.State;
        if (parent.channels_started) return error.Busy;
        // Also reject a channel whose allocation may be visible but has no
        // confirmed Info yet, and conservatively hold after channel Free.
        for (&self.display_channels) |*entry| if (entry.* != null) return error.Busy;
        for (parent.children) |child| if (child != 0) return error.Busy;
        return parent;
    }
    fn mutableDisplayTable(self: *Owner, handle: DisplayEngineHandle) !*display_engine.Owner {
        const parent = try self.findDisplayEngine(handle);
        if (!parent.channels_started) return self.idleDisplayTable(handle);
        if (self.copyBusy() or self.graph_closing or self.sequence.self_address != 0 or self.nativeObject() == null or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown or
            self.display_engine_active or self.display_channel_active != null) return error.Busy;
        try self.displayTableChannelsIdle(parent);
        return parent;
    }
    fn displayTableChannelsIdle(self: *Owner, parent: *display_engine.Owner) !void {
        if (parent.info() == null or !parent.instance_bound) return error.Stale;
        for (&self.display_channels) |*entry| if (entry.*) |*owner| {
            if (owner.parent != parent or owner.info() == null) return error.Busy;
            if (owner.ring.self_address != 0 and (!owner.ring.valid() or owner.ring.pending != null or
                owner.ring.issued != owner.ring.completed)) return error.Busy;
        };
    }
    fn displayImageUnused(self: *Owner, descriptor: display_resources.layout.Descriptor) bool {
        if (descriptor.target != .vram or descriptor.channel == 0 or descriptor.channel > 8) return false;
        for (&self.display_images) |entry| if (entry) |active| if (active.image.dma == descriptor.handle) return false;
        for (&self.presentation_slots) |*slot| if (slot.*) |*entry| if (entry.surface.scanout) |active| if (active.dma == descriptor.handle) return false;
        if (self.display_work != null or self.hasDisplayFlips() or self.initial_image != null or self.copy_job != null) return false;
        return true;
    }
    /// Repeated at the actual Device CE admission boundary, not just at the
    /// caller-facing API. A stale notifier/GET or current image is not a lease
    /// to overwrite its descriptor; additions/removals name unused entries.
    pub fn validateDisplayTableUpdate(self: *Owner) !void {
        const parent = if (self.display_engine_owner) |*value| value else return error.State;
        const resources = self.display_resources_slot.owner orelse return error.State;
        if (!resources.valid() or resources.instance != &parent.instance_storage or
            !std.meta.eql(resources.binding.?, parent.binding)) return error.Stale;
        if (!parent.channels_started) {
            for (&self.display_channels) |*entry| if (entry.* != null) return error.Busy;
            return;
        }
        try self.displayTableChannelsIdle(parent);
        const change = resources.table.change orelse return error.Stale;
        const descriptor = resources.table.entries[change.index] orelse return error.Stale;
        if (!change.remove and descriptor.target == .coherent_system and descriptor.channel > 0 and descriptor.channel <= 8) {
            const index = descriptor.channel - 1;
            const claim = self.output_claims[index] orelse return error.Stale;
            const note = &resources.notifiers[descriptor.channel];
            if (claim.window != index or self.display_channels[descriptor.channel] != null or self.display_images[index] != null or
                !note.valid() or note.handle != descriptor.handle or note.point != 0 or !note.backing.retained or
                resources.table.published(descriptor.channel, descriptor.handle)) return error.Stale;
            return;
        }
        if (self.cursor_storage) |cursor| if (!change.remove and descriptor.channel == 0 and descriptor.handle == cursor.dma and
            descriptor.target == .vram and descriptor.bytes == 2 * cursor_image.max_bytes and resources.surfaces[change.index] == null and
            cursor.active == null and self.cursor_upload == null and self.cursor_point == null) return;
        if (resources.surfaces[change.index] == null or !self.displayImageUnused(descriptor)) return error.Busy;
        if (change.remove and !try resources.imageFinished(descriptor.channel, descriptor.handle)) return error.Busy;
    }
    /// A completed replacement selected another image. Clearing the old
    /// RAMHT binding still precedes releasing its retained native storage.
    pub fn removeDisplayImage(self: *Owner, handle: DisplayEngineHandle, window: u32, dma: u32) !void {
        _ = try self.mutableDisplayTable(handle);
        const resources = self.display_resources_slot.owner orelse return error.State;
        const slot = try display_channel.wire.slot(.window, window);
        const index = resources.table.indexOf(@intCast(slot), dma) orelse return error.Stale;
        if (!self.displayImageUnused(resources.table.entries[index].?)) return error.Busy;
        try resources.removeImage(@intCast(slot), dma);
    }
    fn ensureDisplayResources(self: *Owner, parent: *display_engine.Owner) !*display_resources.Owner {
        const slot = &self.display_resources_slot;
        if (slot.owner) |owner| {
            if (!owner.valid() or !std.meta.eql(owner.binding.?, parent.binding) or owner.instance != &parent.instance_storage) return error.Stale;
            return owner;
        }
        if (slot.allocation.handle != 0) return error.Retained;
        const heap = self.ctx.?.heap() orelse return error.Api; slot.heap = heap;
        const result = heap.allocate(@sizeOf(display_resources.Owner), @alignOf(display_resources.Owner), &slot.allocation);
        const allocation = slot.allocation;
        if (result != r4os.abi.driver_heap_ok and allocation.handle == 0) return error.Memory;
        if (allocation.version != 1 or allocation.size < @sizeOf(r4os.abi.DriverHeapAllocation) or allocation.handle == 0 or
            allocation.cpu_address == 0 or allocation.cpu_address % @alignOf(display_resources.Owner) != 0 or allocation.reserved != 0 or
            allocation.byte_length < @sizeOf(display_resources.Owner) or allocation.alignment < @alignOf(display_resources.Owner) or
            allocation.cpu_address > std.math.maxInt(u64) - allocation.byte_length) { self.stop(error.Descriptor); return error.Descriptor; }
        errdefer if (heap.release(allocation.handle) == r4os.abi.driver_heap_ok) { slot.* = .{}; } else self.stop(error.Retained);
        if (result != r4os.abi.driver_heap_ok) return error.Memory;
        const owner: *display_resources.Owner = @ptrFromInt(allocation.cpu_address); owner.* = .{};
        try owner.open(self.channel.?.session, parent.binding, self.graph.?.reservation, &parent.instance_storage);
        slot.owner = owner; return owner;
    }
    pub fn displayTableStatus(self: *Owner, handle: DisplayEngineHandle) !DisplayTableStatus {
        const parent = try self.findDisplayEngine(handle);
        const owner = self.display_resources_slot.owner orelse return error.State;
        if (parent.info() == null or !owner.valid() or !std.meta.eql(owner.binding.?, parent.binding) or owner.instance != &parent.instance_storage) return error.Stale;
        return .{ .entries = owner.table.count, .revision = owner.table.revision, .published_revision = owner.table.uploaded_revision, .uploading = owner.table.uploading };
    }
    pub fn bindCursorStorage(self: *Owner, handle: DisplayEngineHandle, source: BufferHandle, head: u32) !u32 {
        if (self.cursor_storage != null or self.cursor_upload != null or self.cursor_point != null) return error.Busy;
        const parent = try self.mutableDisplayTable(handle);
        const info = parent.info() orelse return error.State;
        if (!info.cursor or info.cursor_size == 0 or head >= info.hardware.heads) return error.Unsupported;
        _ = try self.headSource(head);
        const storage = try self.findNativeBuffer(source);
        const value = storage.info() orelse return error.State;
        const policy = storage.storage_policy orelse return error.Unsupported;
        if (policy.role != .cursor) return error.Unsupported;
        if (value.logical_bytes != 2 * cursor_image.max_bytes or value.surface.scanout()) return error.Bounds;
        const table_owner = try self.ensureDisplayResources(parent);
        const dma = try table_owner.bindCursor(storage);
        self.cursor_storage = .{ .dma = dma, .head = head };
        return dma;
    }
    pub fn uploadCursorImage(self: *Owner, channel: ChannelHandle, source: r4os.abi.GfxBufferHandle,
        plan: cursor_image.Plan, slot: u1, deadline: u64) !void
    {
        const storage = if (self.cursor_storage) |*value| value else return error.State;
        if (self.copyBusy() or self.cursor_point != null or self.nativeObject() == null or self.graph_closing or
            self.channel.?.phase != .idle or storage.active == slot) return error.Busy;
        const table_owner = self.display_resources_slot.owner orelse return error.State;
        const target = table_owner.publishedCursorStorage(storage.dma) orelse return error.State;
        const root = self.display_engine_owner.?.info() orelse return error.State;
        if (!plan.valid() or plan.size > root.cursor_size) return error.Bounds;
        const fifo = try self.findChannel(channel);
        const config = fifo.info() orelse return error.State;
        if (!config.config.system_userd or !fifo.ring.idle()) return error.Busy;
        const staging = if (self.graph.?.control_buffer) |*value| value else return error.State;
        if (staging.binding.space.handle != fifo.config.context.vaspace or staging.binding.space.client != root.binding.client) return error.Stale;
        try self.channel.?.guard(deadline);
        const input_memory = self.memory_api orelse return error.Api;
        self.cursor_upload = .{ .channel = channel, .slot = slot };
        self.cursor_upload.?.operation.open(input_memory, source, plan, staging, target, @as(u64, slot) * cursor_image.max_bytes, deadline) catch |err| {
            if (self.cursor_upload.?.operation.failure != null) self.stop(err) else self.cursor_upload = null;
            return err;
        };
        storage.uploaded[slot] = null;
        storage.upload_error = null;
    }
    pub fn validateCursorUpload(self: *Owner) !void {
        const work = if (self.cursor_upload) |*value| value else return error.State;
        const storage = self.cursor_storage orelse return error.State;
        const table_owner = self.display_resources_slot.owner orelse return error.State;
        const root = if (self.display_engine_owner) |*value| value else return error.State;
        const info = root.info() orelse return error.State;
        const staging = if (self.graph.?.control_buffer) |*value| value else return error.State;
        if (self.copy_job != null or self.display_upload_job != null or self.initial_image != null or self.display_work != null or
            self.hasDisplayFlips() or self.cursor_point != null or self.graph_closing or !work.operation.valid() or
            work.operation.target != table_owner.publishedCursorStorage(storage.dma) or work.operation.source != staging or
            work.operation.target_offset != @as(u64, work.slot) * cursor_image.max_bytes or storage.active == work.slot or
            work.operation.plan.size > info.cursor_size or !std.meta.eql(table_owner.binding.?, root.binding)) return error.Stale;
        _ = try self.headSource(storage.head);
    }
    pub fn commitCursorImage(self: *Owner, core_handle: DisplayChannelHandle, slot: ?u1, deadline: u64) !u64 {
        const storage = if (self.cursor_storage) |*value| value else return error.State;
        if (self.cursor_point != null or self.cursor_upload != null) return error.Busy;
        if (storage.issued == std.math.maxInt(u64)) return error.Exhausted;
        var core = try self.prepareDisplayCore(core_handle, deadline);
        if (core.config.initialize) return error.State;
        const value: cursor_image.Control = if (slot) |index| blk: {
            const ready = storage.uploaded[index] orelse return error.State;
            if (ready.point == 0) return error.State;
            break :blk .{ .head = storage.head, .dma = storage.dma, .offset = @as(u64, index) * cursor_image.max_bytes,
                .storage_bytes = 2 * cursor_image.max_bytes, .size = ready.plan.size,
                .hotspot_x = ready.plan.hotspot_x, .hotspot_y = ready.plan.hotspot_y, .visible = true };
        } else .{ .head = storage.head };
        try value.validate();
        core.config.cursor_image = value;
        storage.issued += 1;
        self.display_work = .{ .core = core, .deadline = deadline, .cursor = .{ .control = value, .sequence = storage.issued } };
        return storage.issued;
    }
    pub fn validateCursorCommit(self: *Owner) !void {
        const work = self.display_work orelse return error.State;
        const cursor = work.cursor orelse return error.State;
        const storage = self.cursor_storage orelse return error.State;
        const root = self.display_engine_owner.?.info() orelse return error.State;
        const table_owner = self.display_resources_slot.owner orelse return error.State;
        if (self.cursor_upload != null or self.cursor_point != null or work.window != null or work.position != null or work.boot_mode != null or
            work.link != null or work.core.config.initialize or work.core.config.signal != null or work.core.config.route != null or
            work.core.config.cursor_usage != 0 or !std.meta.eql(work.core.config.cursor_image, @as(?cursor_image.Control, cursor.control)) or
            cursor.sequence != storage.issued or cursor.sequence <= storage.completed or cursor.control.head != storage.head or
            !root.cursor or root.cursor_size == 0 or table_owner.publishedCursorStorage(storage.dma) == null) return error.Stale;
        try cursor.control.validate();
        _ = try self.headSource(storage.head);
        if (cursor.control.visible) {
            const position = if (self.display_channels[17 + cursor.control.head]) |*value| value else return error.Stale;
            if (position.info() == null or position.point.pending != null or position.point.completed == null) return error.Stale;
            if (cursor.control.dma != storage.dma or cursor.control.storage_bytes != 2 * cursor_image.max_bytes or
                cursor.control.offset % cursor_image.max_bytes != 0 or cursor.control.size > root.cursor_size) return error.Stale;
            const index = cursor.control.offset / cursor_image.max_bytes;
            if (index >= 2) return error.Stale;
            const ready = storage.uploaded[index] orelse return error.Stale;
            if (ready.point == 0 or !ready.plan.valid() or cursor.control.size != ready.plan.size or
                cursor.control.hotspot_x != ready.plan.hotspot_x or cursor.control.hotspot_y != ready.plan.hotspot_y) return error.Stale;
        }
    }
    pub fn allocateIdentityLutStorage(self: *Owner, deadline: u64) !BufferHandle {
        return self.allocatePrivateStorageRole(@import("gsp_display_identity_lut.zig").allocation_bytes, 65536, false, false, .lut, deadline);
    }
    pub fn bindIdentityLut(self: *Owner, root: DisplayEngineHandle, source: BufferHandle, head: u32, window: u32) !void {
        const parent = try self.mutableDisplayTable(root);
        const resources = self.display_resources_slot.owner orelse return error.State;
        if (window >= 8 or head >= 8 or parent.identity_windows & (@as(u8, 1) << @intCast(window)) == 0 or parent.channels_started) return error.State;
        try resources.bindIdentityLut(try self.findNativeBuffer(source), head, window);
    }
    pub fn uploadIdentityLut(self: *Owner, root: DisplayEngineHandle, handle: ChannelHandle, deadline: u64) !void {
        const parent = try self.mutableDisplayTable(root);
        const resources = self.display_resources_slot.owner orelse return error.State;
        if (parent.channels_started or resources.identity_lut == null or resources.identity_lut.?.ready) return error.State;
        const target = resources.identityLutTarget() orelse return error.Stale;
        const fifo = try self.findChannel(handle);
        const config = fifo.info() orelse return error.State;
        if (!config.config.system_userd or !fifo.ring.idle()) return error.Busy;
        const staging = if (self.graph.?.control_buffer) |*value| value else return error.State;
        if (staging.binding.space.handle != fifo.config.context.vaspace or staging.binding.space.client != parent.binding.client) return error.Stale;
        try self.channel.?.guard(deadline);
        self.display_upload_job = .{ .channel_handle = handle };
        self.display_upload_job.?.operation.openIdentity(staging, target, deadline) catch |err| {
            if (self.display_upload_job.?.operation.failure != null) self.stop(err) else self.display_upload_job = null;
            return err;
        };
    }
    pub fn validateIdentityLutUpload(self: *Owner) !void {
        const work = if (self.display_upload_job) |*value| value else return error.State;
        const parent = if (self.display_engine_owner) |*value| value else return error.State;
        const resources = self.display_resources_slot.owner orelse return error.State;
        const lut = resources.identity_lut orelse return error.State;
        if (work.operation.purpose != .identity_lut or !work.operation.valid() or parent.channels_started or lut.ready or
            lut.control.window >= 8 or parent.identity_windows & (@as(u8, 1) << @intCast(lut.control.window)) == 0 or
            work.operation.target != resources.identityLutTarget() or !std.meta.eql(resources.binding.?, parent.binding)) return error.Stale;
    }
    pub fn identityLutReady(self: *Owner, root: DisplayEngineHandle) !bool {
        _ = try self.findDisplayEngine(root);
        const resources = self.display_resources_slot.owner orelse return error.State;
        if (!resources.valid()) return error.Stale;
        return (resources.identity_lut orelse return error.State).ready;
    }
    pub fn uploadDisplayTable(self: *Owner, root: DisplayEngineHandle, handle: ChannelHandle, deadline: u64) !void {
        const parent = try self.mutableDisplayTable(root);
        const owner = self.display_resources_slot.owner orelse return error.State;
        if (!owner.valid() or !std.meta.eql(owner.binding.?, parent.binding) or owner.instance != &parent.instance_storage) return error.Stale;
        try self.validateDisplayTableUpdate();
        const fifo = try self.findChannel(handle);
        const config = fifo.info() orelse return error.State;
        if (!config.config.system_userd or !fifo.ring.idle()) return error.Busy;
        const staging = if (self.graph.?.control_buffer) |*value| value else return error.State;
        if (staging.binding.space.handle != fifo.config.context.vaspace or staging.binding.space.client != parent.binding.client) return error.Stale;
        try self.channel.?.guard(deadline);
        self.display_upload_job = .{ .channel_handle = handle };
        self.display_upload_job.?.operation.open(&owner.table, staging, &parent.instance_storage, deadline) catch |err| {
            if (self.display_upload_job.?.operation.failure != null) self.stop(err) else self.display_upload_job = null;
            return err;
        };
        if (self.cursor_storage) |cursor| if (owner.table.change) |change| {
            const entry = owner.table.entries[change.index] orelse return error.Stale;
            if (!change.remove and entry.channel == 0 and entry.handle == cursor.dma)
                self.display_upload_job.?.operation.readback_requested = true;
        };
    }
    /// Initial core methods and a notifier-backed UPDATE. This does not
    /// assert that a mode was adopted or that an image is visibly scanned.
    pub fn commitDisplayCore(self: *Owner, handle: DisplayChannelHandle, deadline: u64) !void {
        const core = try self.prepareDisplayCore(handle, deadline);
        self.display_work = .{ .core = core, .deadline = deadline };
    }
    fn prepareDisplayCore(self: *Owner, handle: DisplayChannelHandle, deadline: u64) !DisplaySubmission {
        if (self.anyAdaptiveRefresh()) return error.Busy;
        return self.prepareDisplayCoreInner(handle, deadline);
    }
    fn prepareDisplayCoreInner(self: *Owner, handle: DisplayChannelHandle, deadline: u64) !DisplaySubmission {
        const owner = try self.findDisplayChannel(handle);
        const value = owner.info() orelse return error.State;
        if (value.config.kind != .core) return error.Unsupported;
        if (self.copyBusy() or self.graph_closing or self.sequence.self_address != 0 or self.nativeObject() == null or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        const resources = self.display_resources_slot.owner orelse return error.State;
        const note = resources.publishedNotifier(0) orelse return error.State;
        if (note.phase != .ready and note.phase != .complete) return error.Busy;
        if (resources.instance != &owner.parent.instance_storage or !std.meta.eql(resources.binding.?, value.config.root)) return error.Stale;
        try self.channel.?.guard(deadline);
        if (owner.ring.self_address == 0) owner.ring.open(&owner.backing, value.config, note.point) catch |err| {
            if (err == error.Descriptor or err == error.Retained) self.stop(err); return err;
        };
        const root = owner.parent.info() orelse return error.State;
        return .{ .handle = handle, .notifier = note,
            .config = .{ .notifier = note.handle, .windows = root.hardware.windows, .initialize = !owner.ring.initialized } };
    }
    pub fn anyAdaptiveRefresh(self: *const Owner) bool {
        for (&self.refresh_results) |*entry| if (entry.*) |value| if (value.enabled) return true;
        return false;
    }
    pub fn adaptiveRefreshPlan(self: *Owner, window: u32) !refresh_control.Plan {
        if (window >= 8 or self.outputPaused(window) or self.outputs.invalidated or self.receiver_events.pending or self.receiver_events.capturing) return error.Busy;
        const active = self.display_images[window] orelse return error.State;
        const mode = active.boot_mode orelse return error.State;
        const link = active.link orelse return error.State;
        _ = try self.headSource(mode.head);
        const root = if (self.display_engine_owner) |*value| value else return error.State;
        const info = root.info() orelse return error.State;
        if (!info.core or !info.instance_bound) return error.Unsupported;
        return refresh_control.derive(mode, self.display_object orelse return error.State,
            self.outputs.snapshot() orelse return error.State, link, display_channel.wire.classFor(info.binding, .core));
    }
    pub fn beginAdaptiveRefresh(self: *Owner, core_handle: DisplayChannelHandle, window: u32, enabled: bool, deadline: u64) !u64 {
        if (window >= 8 or self.refresh_sequence == std.math.maxInt(u64)) return error.Descriptor;
        const current = try self.now();
        const plan = if (enabled) try self.adaptiveRefreshPlan(window) else blk: {
            const previous = self.refresh_results[window] orelse return error.State;
            if (!previous.enabled) return error.State;
            break :blk previous.plan;
        };
        if (enabled) if (self.refresh_results[window]) |previous| if (previous.enabled) return error.State;
        var core = try self.prepareDisplayCoreInner(core_handle, deadline);
        if (core.config.initialize or core_handle.slot != 0) return error.State;
        const control = try refresh_control.Work.init(plan, enabled, current, deadline);
        const target = self.presentation_targets[window] orelse return error.State;
        _ = try self.refresh_clocks[window].bindTarget(target);
        try self.refresh_clocks[window].begin(target.display_generation, plan.refresh, enabled, current);
        core.config.refresh_control = .{ .head = plan.mode.head, .enabled = enabled,
            .timeout_us = if (enabled) plan.refresh.timeout_us else 0 };
        self.refresh_sequence += 1;
        self.display_work = .{ .core = core, .deadline = deadline,
            .refresh = .{ .sequence = self.refresh_sequence, .receiver_sequence = self.receiver_events.sequence, .control = control } };
        return self.refresh_sequence;
    }
    pub fn quiesceAdaptiveRefresh(self: *Owner) !void {
        self.refresh_quiescing = true;
        // Only unsubmitted, already-rendered frames are discarded. Current
        // scanout, submitted Window uses and their BO owners remain retained.
        for (0..8) |window| if (self.readyImage(@intCast(window)) != null) {
            try self.setReadyImage(@intCast(window), null);
            self.frames_rejected +|= 1; self.output_frames[window].rejected +|= 1;
        };
    }
    fn observeAdaptiveRefresh(self: *Owner, current: u64) void {
        for (&self.refresh_clocks, 0..) |*pacing, window| {
            const target = self.presentation_targets[window] orelse continue;
            const image = self.display_images[window] orelse continue;
            if (image.boot_mode == null) continue;
            const rebound = pacing.bindTarget(target) catch { pacing.fault(.timing_fault); continue; };
            if (rebound) self.refresh_results[window] = null;
            const source = self.headSource(image.head) catch continue;
            if (source.snapshot()) |sample| pacing.observe(sample);
            pacing.checkClock(current);
        }
    }
    pub fn validateAdaptiveRefresh(self: *Owner) !void {
        const work = if (self.display_work) |*value| value else return error.State;
        const refresh = if (work.refresh) |*value| value else return error.State;
        const control = &refresh.control;
        if (work.window != null or work.position != null or work.link != null or work.cursor != null or work.detach != null or
            work.boot_mode != null or work.admission != null or work.mode_receipt != 0 or work.deadline != control.deadline or
            control.plan.object.epoch != self.epoch or control.plan.mode.window >= 8 or work.core.handle.slot != 0 or
            !std.meta.eql(control.plan.object, self.display_object orelse return error.Stale)) return error.Stale;
        const current = self.display_images[control.plan.mode.window] orelse return error.Stale;
        if (!std.meta.eql(current.boot_mode, @as(?boot_mode.Plan, control.plan.mode)) or current.head != control.plan.mode.head) return error.Stale;
        if (!control.enabled and refresh.failure == null) {
            const previous = self.refresh_results[control.plan.mode.window] orelse return error.Stale;
            if (!previous.enabled or !std.meta.eql(previous.plan, control.plan)) return error.Stale;
        }
        if (refresh.sequence == 0 or refresh.sequence != self.refresh_sequence or
            (control.phase == .core and !control.supervisor_armed)) return error.Stale;
        const expected: display_channel.push.commands.Config = .{ .notifier = work.core.notifier.handle,
            .windows = work.core.config.windows, .initialize = false,
            .refresh_control = .{ .head = control.plan.mode.head, .enabled = control.enabled,
                .timeout_us = if (control.enabled) control.plan.refresh.timeout_us else 0 } };
        if (!std.meta.eql(expected, work.core.config)) return error.Stale;
        _ = try display_channel.push.commands.encode(expected);
    }
    pub fn adaptiveReceiverCurrent(self: *Owner) bool {
        const work = if (self.display_work) |*value| value else return false;
        const refresh = if (work.refresh) |*value| value else return false;
        if (!refresh.control.enabled) return true;
        if (refresh.receiver_sequence != self.receiver_events.sequence) return false;
        const fresh = self.adaptiveRefreshPlan(refresh.control.plan.mode.window) catch return false;
        return std.meta.eql(fresh, refresh.control.plan);
    }
    fn rollbackAdaptiveRefresh(self: *Owner, reason: anyerror, current: u64) !void {
        try self.validateAdaptiveRefresh();
        const work = &self.display_work.?;
        const previous = work.refresh.?;
        const channel = &self.channel.?;
        if (!previous.control.enabled or previous.failure != null or channel.phase != .idle or channel.pending != null or
            channel.in_lockdown or (work.core.phase != .prepare and work.core.phase != .complete)) return reason;
        const deadline = try std.math.add(u64, current, 3 * std.time.ns_per_s);
        try channel.guard(deadline);
        var cleanup = try refresh_control.Work.init(previous.control.plan, false, current, deadline);
        // Finish a possibly armed old supervisor before the independent
        // disable sequence arms it again. At most one rollback is allowed.
        if (previous.control.supervisor_armed or previous.control.phase == .arm) {
            cleanup.cleanup_disarm = true; cleanup.phase = .disarm;
        }
        const core: DisplaySubmission = .{ .handle = work.core.handle, .notifier = work.core.notifier,
            .config = .{ .notifier = work.core.notifier.handle, .windows = work.core.config.windows, .initialize = false,
                .refresh_control = .{ .head = cleanup.plan.mode.head, .enabled = false, .timeout_us = 0 } } };
        work.* = .{ .core = core, .deadline = deadline, .refresh = .{ .sequence = previous.sequence,
            .receiver_sequence = previous.receiver_sequence, .control = cleanup, .failure = reason } };
        const pacing = &self.refresh_clocks[cleanup.plan.mode.window];
        pacing.scheduler.fault = if (reason == error.Stale) .link_lost else .timing_fault;
        pacing.scheduler.reason = pacing.scheduler.fault;
        pacing.scheduler.state = .disabling;
        pacing.since_ns = current;
        self.log("NVIDIA refresh: enable-failed={s} sequence={d} fixed-rollback=pending", .{@errorName(reason),previous.sequence});
    }
    /// Reserve cursor fetch bandwidth before channels can become active.
    /// An IMP rejection can retry the boot mode once with a software cursor.
    pub fn configureIdentityLutUsage(self: *Owner, handle: DisplayEngineHandle, window: u32) !void {
        const root = try self.findDisplayEngine(handle);
        const info = root.info() orelse return error.State;
        if (window >= 8 or !info.core or !info.window or info.hardware.windows & (@as(u32, 1) << @intCast(window)) == 0) return error.Unsupported;
        if (root.channels_started or self.mode_control_active or self.display_work != null or self.graph_closing) return error.Busy;
        root.identity_windows |= @as(u8, 1) << @intCast(window);
    }
    pub fn configureCursorUsage(self: *Owner, handle: DisplayEngineHandle, size: u16) !void {
        const root = try self.findDisplayEngine(handle);
        const info = root.info() orelse return error.State;
        _ = try @import("gsp_cursor_image.zig").usageCode(size);
        if (size != 0 and !info.cursor) return error.Unsupported;
        if (root.channels_started or self.mode_control_active or self.display_work != null or self.graph_closing) return error.Busy;
        root.cursor_size = size;
    }
    /// Derive the candidate again from the actual retained Device capture and
    /// current coherent RM catalog; callers cannot submit arbitrary timings.
    pub fn bootDisplayPlan(self: *Owner, root_handle: DisplayEngineHandle, window: u32) !boot_mode.Plan {
        return self.displayModePlan(root_handle, window, 0);
    }
    pub fn reconnectDisplayPlan(self: *Owner, root_handle: DisplayEngineHandle, window: u32,
        previous: boot_mode.Plan) !@import("gsp_reconnect.zig").Choice
    {
        if (window >= 8) return error.Bounds;
        const snapshot = self.nativeOutputs() orelse return error.Busy;
        const object = self.nativeObject() orelse return error.Busy;
        if (self.output_claims[window]) |claim| {
            const root = try self.findDisplayEngine(root_handle);
            const info = root.info() orelse return error.State;
            const held = self.reservation orelse return error.State;
            _ = try held.binding(.metadata);
            const saved = held.display orelse return error.Stale;
            if (saved.original_boot == null or saved.scanout_original == null) return error.Stale;
            var chosen = try @import("gsp_reconnect.zig").chooseAssigned(.{ .epoch = self.epoch, .held_generation = saved.boot.held_generation,
                .boot_generation = saved.original_boot.?.generation }, &saved.scanout_original.?, info.hardware, snapshot, object, claim, previous);
            chosen.plan.native_lut = root.identity_windows & (@as(u8, 1) << @intCast(window)) != 0;
            return chosen;
        }
        return @import("gsp_reconnect.zig").choose(try self.bootDisplayPlan(root_handle, window), snapshot, object, previous);
    }
    pub fn displayModePlan(self: *Owner, root_handle: DisplayEngineHandle, window: u32, receiver_mode_id: u32) !boot_mode.Plan {
        const root = try self.findDisplayEngine(root_handle);
        const info = root.info() orelse return error.State;
        const held = self.reservation orelse return error.State;
        _ = try held.binding(.metadata);
        const saved = held.display orelse return error.Stale;
        if (saved.original_boot == null or saved.scanout_original == null or saved.boot.held_generation == 0 or
            saved.chip == null or !@import("generation.zig").ga102Hal(saved.chip.?.id)) return error.Stale;
        if (window >= 8) return error.Bounds;
        if (!info.core or !info.window or
            info.hardware.windows & (@as(u32, 1) << @intCast(window)) == 0) return error.Unsupported;
        // Pure revalidation also runs while the mode-control owner holds the
        // canonical exchange. Requiring the main exchange here would exclude
        // the actual RPC gate; accepting caller-supplied timings would forge
        // the source of an otherwise valid RM query.
        const channel = self.activeChannel() orelse return error.Busy;
        if (self.graph == null or self.graph.?.state != .loaned or self.display_object == null or self.channel == null or
            channel.session.state != .active or self.failure != null) return error.Busy;
        const snapshot = self.outputs.snapshot() orelse return error.Busy;
        var bound = if (self.output_claims[window]) |claim| try output_route.derive(.{ .epoch = self.epoch,
            .held_generation = saved.boot.held_generation, .boot_generation = saved.original_boot.?.generation },
            &saved.scanout_original.?, info.hardware, snapshot, claim, receiver_mode_id) else blk: {
            const plan = try boot_mode.capture(&saved.scanout_original.?, &saved.original_boot.?, window);
            if (plan.head >= info.hardware.heads) return error.Unsupported;
            const initial = try boot_mode.bind(plan, snapshot, self.epoch, saved.boot.held_generation);
            if (receiver_mode_id != 0) break :blk try @import("gsp_receiver_mode.zig").select(initial, snapshot, receiver_mode_id);
            // The pending callback generation does not select a consumer:
            // common failure recovery can request it after native reset was
            // already chosen. Only the actual bound new console does so.
            if (self.boot_console_restore) |console_owner| {
                if (console_owner.lease != held or !console_owner.valid(self.epoch)) return error.Stale;
                break :blk initial;
            }
            break :blk try @import("gsp_receiver_mode.zig").admitBootHdmi(initial, snapshot);
        };
        bound.cursor_size = info.cursor_size;
        bound.native_lut = root.identity_windows & (@as(u8, 1) << @intCast(window)) != 0;
        return bound;
    }
    pub fn displayColorModePlan(self: *Owner, root: DisplayEngineHandle, window: u32, receiver_mode_id: u32,
        color: ?@import("gsp_color_signal.zig").color.Signal, pipeline: @import("gsp_color_signal.zig").color.Pipeline) !boot_mode.Plan
    {
        var plan = try self.displayModePlan(root, window, receiver_mode_id);
        plan.color = color; plan.color_pipeline = pipeline;
        if (color) |signal| {
            plan.signal.bpc = signal.bpc;
            plan.signal.dp_vsc = plan.displayPort() and @import("gsp_color_signal.zig").needsVsc(signal);
        } else if (pipeline.linear_composition or pipeline.output_transform or pipeline.opaque_output) return error.Descriptor;
        const current_outputs = self.outputs.snapshot() orelse return error.Stale;
        if (plan.signal.mst != null) try @import("gsp_mst_mode.zig").validate(plan, current_outputs);
        for (current_outputs.receivers[0..current_outputs.count]) |*receiver| if (receiver.display_id == plan.signal.display_id) {
            plan = try @import("gsp_frl_link.zig").select(plan, &receiver.report);
            plan = try @import("gsp_dp_mode.zig").select(plan,receiver);
            break;
        };
        try display_link.validate(plan, self.display_object.?, self.outputs.snapshot().?);
        return plan;
    }
    fn outputRouteClaims(self: *Owner, snapshot: *const outputs.Snapshot) ![8]?output_route.Claim {
        var occupied = self.output_claims;
        for (&self.display_images, 0..) |*slot, index| if (slot.*) |image| {
            const claim = try output_route.identify(image.boot_mode orelse return error.Stale, snapshot);
            if (claim.window != index or (occupied[index] != null and !std.meta.eql(occupied[index].?, claim))) return error.Stale;
            occupied[index] = claim;
        };
        return occupied;
    }
    pub fn beginSorAssignment(self: *Owner, root: DisplayEngineHandle, display_id: u32, deadline: u64) !u64 {
        _ = try self.findDisplayEngine(root);
        const current = try self.now();
        if (self.sor_work != null or self.sor_result != null or self.sor_boot != null or !self.cursorWorkAvailable() or self.display_paused or
            !self.presentationValid() or self.channel.?.phase != .idle or self.sequence.self_address != 0) return error.Busy;
        if (deadline <= current or self.sor_sequence == std.math.maxInt(u64)) return error.Deadline;
        const snapshot = self.outputs.snapshot() orelse return error.Stale;
        const occupied = try self.outputRouteClaims(snapshot);
        const source = try output_route.assignment(self.display_object.?, snapshot, &occupied, display_id);
        self.sor_sequence += 1;
        self.sor_work = .{ .request = source.request, .connector = source.connector, .fingerprint = source.fingerprint,
            .generation = snapshot.generation, .sequence = self.sor_sequence, .deadline = deadline };
        self.sor_root = root;
        return self.sor_sequence;
    }
    fn bootSorSource(self: *Owner, root_handle: DisplayEngineHandle, saved: boot_mode.Plan,
        identity: output_route.RestoreIdentity, snapshot: *const outputs.Snapshot) !output_route.Assignment
    {
        const root = try self.findDisplayEngine(root_handle);
        const info = root.info() orelse return error.State;
        if (self.presentation != null or root.channels_started or self.failure != null or self.graph_closing) return error.Busy;
        for (&self.display_images) |*slot| if (slot.* != null) return error.Busy;
        for (&self.output_claims) |*slot| if (slot.* != null) return error.Busy;
        const held = self.reservation orelse return error.State;
        _ = try held.binding(.metadata);
        const captured = held.display orelse return error.Stale;
        if (captured.original_boot == null or captured.scanout_original == null or captured.boot.held_generation == 0 or
            captured.chip == null or !@import("generation.zig").ga102Hal(captured.chip.?.id)) return error.Stale;
        if (saved.window >= 8 or saved.head >= info.hardware.heads or !info.core or !info.window or
            info.hardware.windows & (@as(u32, 1) << @intCast(saved.window)) == 0) return error.Unsupported;
        const original = try boot_mode.capture(&captured.scanout_original.?, &captured.original_boot.?, saved.window);
        if (!std.meta.eql(original, saved)) return error.Stale;
        // During this owner's own RPC nativeObject() deliberately hides the
        // display. Validate the already bound main exchange and NV0073 object
        // instead; an unrelated loan or failed session remains inadmissible.
        if (self.graph == null or self.graph.?.state != .loaned or self.channel == null or
            self.activeChannel() != &self.channel.? or self.channel.?.session.state != .active or self.display_object == null) return error.Busy;
        const occupied = try self.outputRouteClaims(snapshot);
        return output_route.restoreAssignment(self.display_object.?, snapshot, &occupied, saved, identity);
    }
    /// Separate bootstrap admission: there is no primary presentation yet.
    /// All ordinary additional-output callers still need presentationValid.
    pub fn beginBootSorAssignment(self: *Owner, root: DisplayEngineHandle, saved: boot_mode.Plan,
        identity: output_route.RestoreIdentity, deadline: u64) !u64
    {
        const current = try self.now();
        if (self.sor_work != null or self.sor_result != null or self.sor_boot != null or !self.cursorWorkAvailable() or
            self.display_paused or self.channel.?.phase != .idle or self.sequence.self_address != 0) return error.Busy;
        if (deadline <= current or self.sor_sequence == std.math.maxInt(u64)) return error.Deadline;
        const snapshot = self.nativeOutputs() orelse return error.Busy;
        const source = try self.bootSorSource(root, saved, identity, snapshot);
        self.sor_sequence += 1;
        self.sor_boot = .{ .plan = saved, .identity = identity };
        self.sor_work = .{ .request = source.request, .connector = source.connector, .fingerprint = source.fingerprint,
            .generation = snapshot.generation, .sequence = self.sor_sequence, .deadline = deadline };
        self.sor_root = root;
        return self.sor_sequence;
    }
    pub fn validateSorAssignment(self: *Owner) !void {
        const work = self.sor_work orelse return error.State;
        const root = self.sor_root orelse return error.State;
        _ = try self.findDisplayEngine(root);
        if (self.failure != null or self.graph_closing or self.display_object == null or self.activeChannel() != &self.channel.? or
            work.obsolete or work.complete or work.request.object.epoch != self.epoch) return error.Stale;
        const snapshot = self.outputs.snapshot() orelse return error.Stale;
        if (snapshot.generation != work.generation) return error.Stale;
        const expected = if (self.sor_boot) |saved| try self.bootSorSource(root, saved.plan, saved.identity, snapshot) else blk: {
            const occupied = try self.outputRouteClaims(snapshot);
            break :blk try output_route.assignment(self.display_object.?, snapshot, &occupied, work.request.display_id);
        };
        if (!std.meta.eql(expected.request, work.request) or !std.meta.eql(expected.connector, work.connector) or
            !std.meta.eql(expected.fingerprint, work.fingerprint)) return error.Stale;
    }
    pub fn sorAssignmentStatus(self: *Owner, sequence: u64) !?SorAssignmentResult {
        _ = try self.now();
        const work = self.sor_work orelse return error.Stale;
        if (sequence == 0 or work.sequence != sequence) return error.Stale;
        if (!work.complete) return null;
        return .{ .root = self.sor_root.?, .sequence = sequence, .generation = work.generation, .receipt = work.receipt,
            .source = .{ .request = work.request, .connector = work.connector, .fingerprint = work.fingerprint },
            .crossbar = work.crossbar(), .assignment = work.assignment, .rejected = if (work.rejected) |value| value.status else null,
            .rpc_error = if (work.rejected) |value| value.rpc else false, .obsolete = work.obsolete };
    }
    /// Consume the ACKed transaction. A successful assignment remains reserved
    /// until its route is claimed or explicitly abandoned. Every attempted
    /// setter requires a fresh whole-topology capture, even after rejection.
    pub fn finishSorAssignment(self: *Owner, sequence: u64) !SorAssignmentResult {
        const result = (try self.sorAssignmentStatus(sequence)) orelse return error.Busy;
        const refresh = self.sor_work.?.operation == .assign;
        if (self.sor_work.?.pending or self.channel.?.phase != .idle or self.channel.?.pending != null) return error.Busy;
        if (refresh) {
            try self.outputs.invalidate();
            try self.receiver_events.refreshOutput(self.epoch, try self.now(), result.source.request.display_id);
        }
        if (!result.obsolete and result.rejected == null and result.receipt != 0) self.sor_result = result;
        if (self.sor_result == null) self.sor_boot = null;
        self.sor_work = null; self.sor_root = null;
        return result;
    }
    pub fn abandonSorAssignment(self: *Owner, sequence: u64) !void {
        const result = self.sor_result orelse return error.Stale;
        if (result.sequence != sequence or self.sor_work != null) return error.Stale;
        // No head/channel has acquired this assignment yet. RM can reuse an
        // inactive, unexcluded SOR; there is no invented free-control RPC.
        for (&self.output_claims) |*slot| if (slot.*) |claim| if (claim.display_id == result.source.request.display_id) return error.Retained;
        self.sor_result = null;
        self.sor_boot = null;
    }
    /// Transfer the ACKed reservation to boot startup only after a fresh whole
    /// topology proves the exact old SOR. No arbitrary timing or active peer
    /// is accepted and there is no invented RM free-control.
    pub fn finishBootSorAssignment(self: *Owner, root: DisplayEngineHandle, sequence: u64, saved: boot_mode.Plan) !boot_mode.Plan {
        const retained = self.sor_boot orelse return error.Stale;
        const result = self.sor_result orelse return error.Stale;
        if (!std.meta.eql(retained.plan, saved) or result.sequence != sequence or !std.meta.eql(result.root, root) or
            result.obsolete or result.rejected != null or result.receipt == 0 or !result.crossbar or result.assignment == null) return error.Stale;
        const snapshot = self.nativeOutputs() orelse return error.Busy;
        if (snapshot.generation <= result.generation) return error.Busy;
        const current = try self.bootSorSource(root, saved, retained.identity, snapshot);
        if (!std.meta.eql(current, result.source) or result.assignment.?.sor != saved.signal.sor) return error.Stale;
        const held = self.reservation.?.display.?;
        const plan = try boot_mode.bind(saved, snapshot, self.epoch, held.boot.held_generation);
        if (!std.meta.eql(try output_route.identify(plan, snapshot), retained.identity.claim)) return error.Stale;
        self.sor_result = null; self.sor_boot = null;
        return plan;
    }
    /// A physical MST port has no display mode to claim. Finish its SOR
    /// reservation only after the new capture proves the assigned source,
    /// branch graph and resource; virtual leaves claim their own heads later.
    pub fn finishMstRootAssignment(self: *Owner, root_handle: DisplayEngineHandle, sequence: u64) !void {
        if (self.sor_boot != null) return error.Binding;
        const result = self.sor_result orelse return error.Stale;
        if (result.sequence != sequence or !std.meta.eql(result.root, root_handle) or result.obsolete or
            result.rejected != null or result.assignment == null or result.receipt == 0) return error.Stale;
        const snapshot = self.nativeOutputs() orelse return error.Busy;
        if (snapshot.generation <= result.generation) return error.Busy;
        const occupied = try self.outputRouteClaims(snapshot);
        const current = try output_route.assignment(self.display_object.?, snapshot, &occupied, result.source.request.display_id);
        if (!std.meta.eql(current, result.source)) return error.Stale;
        const root = try self.outputs.mst_store.root(result.source.request.display_id);
        if (!root.graph.coherent or root.graph.epoch != self.epoch or root.graph.generation != snapshot.generation or
            root.failure != null or root.payload_dirty or root.source == null or !root.source.?.mst or root.resource == null or
            root.resource.?.index != result.assignment.?.sor or root.transaction.phase != .vacant) return error.Unsupported;
        try self.abandonSorAssignment(sequence);
    }
    pub fn claimAssignedDisplayRoute(self: *Owner, root: DisplayEngineHandle, sequence: u64, mode_id: u32) !boot_mode.Plan {
        if (self.sor_boot != null) return error.Binding;
        const result = self.sor_result orelse return error.Stale;
        if (result.sequence != sequence or !std.meta.eql(result.root, root) or result.obsolete or result.rejected != null) return error.Stale;
        const snapshot = self.nativeOutputs() orelse return error.Busy;
        if (result.crossbar and snapshot.generation <= result.generation) return error.Busy;
        const occupied = try self.outputRouteClaims(snapshot);
        const current = try output_route.assignment(self.display_object.?, snapshot, &occupied, result.source.request.display_id);
        if (!std.meta.eql(current, result.source)) return error.Stale;
        const plan = try self.claimDisplayRoute(root, result.source.request.display_id, mode_id);
        if (result.assignment) |assigned| if (plan.signal.sor != assigned.sor) {
            self.output_claims[plan.window] = null;
            return error.Stale;
        };
        self.sor_result = null;
        return plan;
    }
    pub const RefreshedDisplay = struct { mode: boot_mode.Plan, link: display_link.Plan, image: ActiveDisplayImage };
    fn refreshPlan(saved: boot_mode.Plan, snapshot: *const outputs.Snapshot) !boot_mode.Plan {
        var value = try boot_mode.bind(saved, snapshot, saved.epoch, saved.held_generation);
        if (saved.receiver_mode_id != 0) {
            value.receiver_mode_id = 0; value.cta_vic = 0;
            value = try @import("gsp_receiver_mode.zig").select(value, snapshot, saved.receiver_mode_id);
        }
        var expected = saved;
        expected.output_generation = snapshot.generation;
        expected.receipt_serial = snapshot.final_receipt_serial;
        if (!std.meta.eql(expected, value)) return error.Stale;
        return value;
    }
    fn refreshLink(saved: display_link.Plan, mode: boot_mode.Plan, snapshot: *const outputs.Snapshot) !display_link.Plan {
        var expected = saved; expected.mode = mode;
        switch (expected.transport) { .hdmi => |*value| value.mode = mode, .dp => |*value| value.mode = mode, .mst => |*value| value.mode = mode }
        const value = try display_link.derive(mode, saved.object, snapshot);
        if (!std.meta.eql(expected, value)) return error.Stale;
        return value;
    }
    /// Revalidate unchanged physical state after an unrelated connector query.
    /// Only capture generations change. Existing command/visibility receipts
    /// stay attached to their actual image; no setter or new mode proof occurs.
    pub fn refreshDisplayMetadata(self: *Owner, base: boot_mode.Plan, link: display_link.Plan) !RefreshedDisplay {
        var refreshed: RefreshedDisplay = undefined;
        try self.refreshDisplayMetadataInPlace(&refreshed, base, link);
        return refreshed;
    }
    // Build one caller-owned unpublished result. Keeping active, next and
    // returned whole-image copies simultaneously exhausts the task stack.
    pub noinline fn refreshDisplayMetadataInPlace(self: *Owner, refreshed: *RefreshedDisplay, base: boot_mode.Plan, link: display_link.Plan) !void {
        if (!self.cursorWorkAvailable() or self.mode_control_active or self.outputPaused(base.window) or base.window >= 8) return error.Busy;
        const snapshot = self.nativeOutputs() orelse return error.Busy;
        const active = if (self.display_images[base.window]) |*value| value else return error.Stale;
        if (active.boot_mode == null or active.link == null or !active.link.?.complete() or
            active.core_point == 0 or active.window_point == 0 or !std.meta.eql(base, link.mode)) return error.Stale;
        refreshed.mode = try refreshPlan(base, snapshot);
        refreshed.link = try refreshLink(link, refreshed.mode, snapshot);
        refreshed.image = active.*;
        refreshed.image.boot_mode = try refreshPlan(active.boot_mode.?, snapshot);
        refreshed.image.link.?.plan = try refreshLink(active.link.?.plan, refreshed.image.boot_mode.?, snapshot);
        self.display_images[base.window] = refreshed.image;
    }
    fn advanceSorAssignment(self: *Owner, current: u64) !Progress {
        const work = &self.sor_work.?;
        const channel = &self.channel.?;
        if (work.complete) return .idle;
        if (current >= work.deadline) return error.Timeout;
        self.validateSorAssignment() catch { work.obsolete = true; };
        if (work.obsolete and (!work.pending or channel.phase == .prepared)) {
            if (channel.phase == .prepared) try channel.cancelPrepared();
            work.pending = false; work.complete = true;
            return .progress;
        }
        if (!work.pending) {
            work.length = try sor_assignment.encode(work.request, work.operation, &work.bytes);
            try channel.begin(sor_assignment.function, work.bytes[0..work.length], work.deadline);
            work.pending = true;
            return .progress;
        }
        if (try channel.poll(work.deadline)) |dispatch| {
            if (!dispatch.response) { try self.notification(channel, dispatch, current); return .progress; }
            const reply = try sor_assignment.decode(work.request, work.operation, dispatch.record);
            try channel.complete(dispatch.ticket);
            try work.consume(reply, dispatch.ticket.serial);
            return .progress;
        }
        return if (channel.phase == .waiting) .idle else .progress;
    }
    /// Reserve one additional physical route after primary takeover. The
    /// claim is only admission metadata; channels, images and a real mode
    /// receipt still have to be created before common output registration.
    pub fn claimDisplayRoute(self: *Owner, root_handle: DisplayEngineHandle, display_id: u32, mode_id: u32) !boot_mode.Plan {
        const root = try self.findDisplayEngine(root_handle);
        const info = root.info() orelse return error.State;
        if (self.nativeObject() == null or self.display_paused or self.graph_closing or !self.presentationValid()) return error.Busy;
        const primary = self.presentation.?;
        const active = self.display_images[primary.window.slot - 1] orelse return error.State;
        const snapshot = self.nativeOutputs() orelse return error.Busy;
        const held = self.reservation orelse return error.State;
        _ = try held.binding(.metadata);
        const saved = held.display orelse return error.Stale;
        if (saved.scanout_original == null or saved.original_boot == null) return error.Stale;
        _ = active;
        const occupied = try self.outputRouteClaims(snapshot);
        const chosen = try output_route.choose(.{ .epoch = self.epoch, .held_generation = saved.boot.held_generation,
            .boot_generation = saved.original_boot.?.generation }, &saved.scanout_original.?, info.hardware,
            snapshot, &occupied, display_id, mode_id);
        const slot = chosen.claim.window;
        if (self.display_images[slot] != null or self.display_channels[slot + 1] != null or self.display_channels[slot + 9] != null) return error.Busy;
        try display_link.validate(chosen.plan, self.display_object.?, snapshot);
        if (chosen.claim.mst) |stamp| try self.outputs.mst_store.registry.holdRoute(stamp.handle,
            .{ .head = chosen.claim.head, .window = slot });
        self.output_claims[slot] = chosen.claim;
        return chosen.plan;
    }
    pub fn releaseDisplayRoute(self: *Owner, root: DisplayEngineHandle, window: u32) !void {
        _ = try self.findDisplayEngine(root);
        if (window >= 8 or self.output_claims[window] == null) return error.Stale;
        if (self.display_images[window] != null or self.display_channels[window + 1] != null or
            self.display_channels[window + 9] != null or self.display_work != null or self.mode_control_active) return error.Busy;
        for (&self.presentation_slots) |*slot| if (slot.*) |*entry| if (entry.window.slot == window + 1) return error.Retained;
        const claim = self.output_claims[window].?;
        if (claim.mst) |stamp| try self.outputs.mst_store.registry.releaseRoute(stamp.handle, .{ .head = claim.head, .window = window });
        self.output_claims[window] = null;
    }
    /// Called only after the common output API returned success. Receiver
    /// metadata publication alone never acquires a displayed leaf ID.
    pub fn recordMstPublication(self: *Owner, mode: boot_mode.Plan, output: r4os.abi.GfxOutputId, published: bool) !void {
        const stamp = mode.signal.mst orelse return;
        const backend = self.copy_backend orelse return error.Stale;
        if (stamp.handle.epoch != self.epoch or output.connector_id != stamp.display_id or output.adapter_id != self.adapter_id or
            output.device_generation != backend.binding.device_generation or output.connection_generation == 0) return error.Stale;
        if (published) {
            if (mode.window >= 8) return error.Stale;
            const active = self.display_images[mode.window] orelse return error.Stale;
            if (active.boot_mode == null or !std.meta.eql(active.boot_mode.?.signal.mst, mode.signal.mst) or
                active.link == null or !active.link.?.complete()) return error.Stale;
            try self.outputs.mst_store.registry.publish(stamp.handle, active.boot_mode.?.output_generation);
        } else try self.outputs.mst_store.registry.unpublish(stamp.handle);
    }
    fn retainMstImage(self: *Owner, active: ActiveDisplayImage) !void {
        const mode = active.boot_mode orelse return;
        const stamp = mode.signal.mst orelse return;
        try self.outputs.mst_store.registry.activated(stamp.handle, active);
    }
    pub fn displayPeerWindows(self: *const Owner, window: u32) !u8 {
        var mask: u8 = 0;
        for (&self.display_images, 0..) |*slot, index| if (index != window) if (slot.*) |*active| {
            if (active.core_point == 0 or active.window_point == 0 or active.image.dma == 0) return error.Stale;
            mask |= @as(u8, 1) << @intCast(index);
        };
        return mask;
    }
    /// Carry the exact boot signal and primary position in one interlocked
    /// WIMM/Window/Core transaction. Common native adoption follows separately.
    pub fn commitBootDisplayImage(self: *Owner, core_handle: DisplayChannelHandle, window_handle: DisplayChannelHandle, image_handle: u32, deadline: u64) !void {
        return self.commitModeDisplayImage(core_handle, window_handle, image_handle, 0, deadline);
    }
    /// A receiver mode requires the matching completed source-clock/IMP
    /// query. The image and all interlocked channels must already be prepared;
    /// this operation does not allocate buffers or change common geometry.
    pub fn commitModeDisplayImage(self: *Owner, core_handle: DisplayChannelHandle, window_handle: DisplayChannelHandle,
        image_handle: u32, receiver_mode_id: u32, deadline: u64) !void
    {
        return self.commitColorModeDisplayImage(core_handle, window_handle, image_handle, receiver_mode_id, null,
            .{ .linear_composition = false, .output_transform = false, .opaque_output = false }, deadline);
    }
    pub fn commitColorModeDisplayImage(self: *Owner, core_handle: DisplayChannelHandle, window_handle: DisplayChannelHandle,
        image_handle: u32, receiver_mode_id: u32, color: ?@import("gsp_color_signal.zig").color.Signal,
        pipeline: @import("gsp_color_signal.zig").color.Pipeline, deadline: u64) !void
    {
        const core = try self.findDisplayChannel(core_handle);
        const window = try self.findDisplayChannel(window_handle);
        if (core.parent != window.parent or window.config.kind != .window) return error.Stale;
        const root: DisplayEngineHandle = .{ .epoch = self.epoch, .root = core.parent.binding.root };
        const plan = try self.admittedDisplayMode(root, try self.displayColorModePlan(root, window.config.index, receiver_mode_id, color, pipeline));
        const shared_sor = try @import("gsp_mst_sor.zig").control(plan, &self.display_images, false);
        const peer_windows = try self.displayPeerWindows(plan.window);
        if (self.display_link_failures[plan.window] != null) return error.Busy;
        const link = try display_link.derive(plan, self.display_object.?, self.outputs.snapshot().?);
        const receipt = try self.modeAdmission(root, plan);
        var clear_previous: ?display_link.Plan = null;
        var clear_dsc = false;
        if (self.display_images[plan.window]) |*prior| if (prior.link) |*previous_link| {
            clear_dsc = previous_link.plan.mode.signal.dp_dsc != null or previous_link.plan.mode.signal.hdmi_dsc != null;
            if (clear_dsc or (!plan.signal.hdmi_frl and previous_link.plan.mode.signal.hdmi_frl)) {
                if (!previous_link.complete()) return error.Stale;
                clear_previous = previous_link.plan;
            }
        };
        const resources = self.display_resources_slot.owner orelse return error.State;
        const image = resources.publishedImage(window_handle.slot, image_handle) orelse return error.State;
        const format = if (plan.color) |encoding| switch (encoding.format) {
            .xr24 => r4os.abi.gfx_buffer_format_xrgb8888,
            .xr30 => r4os.abi.gfx_buffer_format_xrgb2101010,
        } else r4os.abi.gfx_buffer_format_xrgb8888;
        if (image.width != plan.width or image.height != plan.height or image.format != format) return error.Descriptor;
        const slot = try display_channel.wire.slot(.immediate, window.config.index);
        const position = if (self.display_channels[slot]) |*value| value else return error.Unsupported;
        try self.commitPositionedDisplayImage(core_handle, window_handle,
            .{ .epoch = self.epoch, .handle = position.config.handle, .slot = @intCast(slot) }, image_handle, plan.head, .{}, deadline);
        errdefer self.display_work = null;
        self.display_work.?.link = @as(display_link.Work, undefined);
        const link_work = &self.display_work.?.link.?;
        link_work.initInPlace(link);
        if (clear_previous) |previous| try link_work.clearPrevious(previous);
        try @call(.never_inline, display_link.Work.reserveMst, .{ link_work, self.outputs.snapshot().?, &self.outputs.mst_store, deadline });
        self.display_work.?.core.config.signal = plan.signal;
        const identity = if (plan.native_lut) resources.identityLutControls(plan.head, plan.window) orelse return error.Busy else null;
        self.display_work.?.core.config.identity_lut = identity;
        self.display_work.?.window.?.config.identity_lut = identity;
        if (self.display_work.?.ownership) |*part| part.config.identity_lut = identity;
        self.display_work.?.core.config.mst_sor_control = shared_sor;
        self.display_work.?.core.config.preserve_windows = peer_windows;
        if (self.display_work.?.ownership) |*part| {
            part.config.preserve_windows = peer_windows;
            part.config.signal = plan.signal;
            part.config.cursor_usage = plan.cursor_size;
            part.config.mst_sor_control = shared_sor;
            part.config.clear_dsc = clear_dsc;
        }
        self.display_work.?.core.config.clear_dsc = clear_dsc;
        self.display_work.?.core.config.cursor_usage = plan.cursor_size;
        self.display_work.?.boot_mode = plan;
        self.display_work.?.mode_receipt = receipt;
        self.display_work.?.admission = .{ .mode = plan, .link = link, .receipt = receipt, .receiver_sequence = self.receiver_events.sequence };
        if (self.digitalMonitorSleeping(link)) {
            if (!self.outputPaused(plan.window) or self.display_images[plan.window] != null or self.display_retired[plan.window] == null)
                return error.Stale;
            const work = &self.display_work.?;
            // NULL ISO retirement retains the logical Window assignment,
            // but disconnects the physical head/SOR. Bind it again even when
            // the remembered Window-to-head number has not changed.
            if (work.ownership == null) {
                work.ownership = work.core;
                work.ownership.?.config.ownership_only = true;
                work.core.config.initialize = false;
            }
            work.wake_before_link = true;
        }
        if (!window.ring.initialized) {
            // Bounded retained-owner diagnostics before the first PUT. No
            // register reads, extra leases or commands enter this path.
            self.log("NVIDIA display-commit: epoch={d} head={d} window={d} width={d} height={d} pitch={d} format={x} offset={x} dma={x}",
                .{self.epoch,plan.head,plan.window,image.width,image.height,image.pitch,image.format,image.offset,image.dma});
            for (&resources.table.entries) |*entry| if (entry.*) |*descriptor| {
                self.log("NVIDIA display-context: channel={d} handle={x} target={s} base={x} bytes={d} flags={x} client={x} revision={d}",
                    .{descriptor.channel,descriptor.handle,@tagName(descriptor.target),descriptor.physical,descriptor.bytes,
                        @import("gsp_display_table.zig").descriptor(descriptor.*)[0],resources.table.client,resources.table.uploaded_revision});
            };
        }
    }
    fn modeAdmission(self: *Owner, root: DisplayEngineHandle, plan: boot_mode.Plan) !u64 {
        if (plan.receiver_mode_id == 0 and !self.require_mode_receipt) return 0;
        if (self.mode_control_active) return error.Busy;
        const owner = if (self.mode_control_owner) |*value| value else return error.State;
        if (self.mode_control_root == null or !std.meta.eql(self.mode_control_root.?, root)) return error.Stale;
        const result = owner.infoRef() orelse return error.Busy;
        if (!std.meta.eql(result.mode, plan) or !result.possible or result.over_clock or result.receipt == 0) return error.Unsupported;
        if (plan.signal.hdmi_frl != (result.frl_capacity != null)) return error.Unsupported;
        if (result.frl_capacity) |capacity| if (!std.meta.eql(capacity.compressed, plan.signal.hdmi_dsc) or
            capacity.capacity_receipt == 0 or capacity.capacity_receipt >= result.receipt) return error.Stale;
        if (!plan.sameIntent(owner.mode)) return error.Stale;
        try self.validateModeTopology(root, owner.mode, &owner.topology);
        if (self.display_images[plan.window]) |*prior| if (result.receipt <= prior.mode_receipt) return error.Stale;
        return result.receipt;
    }
    fn admittedDisplayMode(self: *Owner, root: DisplayEngineHandle, intent: boot_mode.Plan) !boot_mode.Plan {
        if (!intent.signal.hdmi_frl) return intent;
        const owner = if (self.mode_control_owner) |*value| value else return error.State;
        if (self.mode_control_active or self.mode_control_root == null or !std.meta.eql(self.mode_control_root.?, root)) return error.Busy;
        const result = owner.infoRef() orelse return error.Busy;
        if (!intent.sameIntent(result.mode)) return error.Stale;
        _ = try self.modeAdmission(root, result.mode);
        return result.mode;
    }
    pub noinline fn commitPositionedDisplayImage(self: *Owner, core_handle: DisplayChannelHandle, window_handle: DisplayChannelHandle,
        immediate_handle: DisplayChannelHandle, image_handle: u32, head: u32, point: display_channel.push.commands.Point, deadline: u64) !void
    {
        const window = try self.findDisplayChannel(window_handle);
        const owner = try self.findDisplayChannel(immediate_handle);
        const value = owner.info() orelse return error.State;
        const root = owner.parent.info() orelse return error.State;
        if (!root.immediate or value.config.kind != .immediate or window.config.kind != .window or owner.parent != window.parent or
            value.config.index != window.config.index or immediate_handle.slot != 9 + window.config.index) return error.Unsupported;
        if (self.copyBusy()) return error.Busy;
        if (owner.ring.self_address == 0) owner.ring.open(&owner.backing, value.config, 0) catch |err| {
            if (err == error.Descriptor or err == error.Retained) self.stop(err); return err;
        };
        if (!owner.ring.valid() or owner.ring.pending != null or owner.ring.issued != owner.ring.completed) return error.Busy;
        try self.commitDisplayImage(core_handle, window_handle, image_handle, head, deadline);
        const work = &self.display_work.?;
        work.window.?.config.with_position = true;
        work.position = .{ .handle = immediate_handle, .config = .{ .kind = .immediate, .notifier = 0, .windows = root.hardware.windows,
            .initialize = !owner.ring.initialized, .route = work.window.?.config.route, .position = point } };
    }
    pub fn commitDisplayImage(self: *Owner, core_handle: DisplayChannelHandle, window_handle: DisplayChannelHandle, image_handle: u32, head: u32, deadline: u64) !void {
        if (self.presentation != null) {
            const entry = try self.findPresentationImage(image_handle);
            if (!self.preparedPresentation(entry) or !std.meta.eql(entry.window, window_handle)) return error.Stale;
            if (entry.initial_point == 0) return error.Busy;
        }
        const owner = try self.findDisplayChannel(window_handle);
        const value = owner.info() orelse return error.State;
        if (value.config.kind != .window) return error.Unsupported;
        const root = owner.parent.info() orelse return error.State;
        if (head >= root.hardware.heads) return error.Bounds;
        const resources = self.display_resources_slot.owner orelse return error.State;
        const image = resources.publishedImage(window_handle.slot, image_handle) orelse return error.State;
        const note = resources.publishedNotifier(window_handle.slot) orelse return error.State;
        const offset = try note.nextWindowOffset();
        var core = try self.prepareDisplayCore(core_handle, deadline);
        const core_owner = try self.findDisplayChannel(core_handle);
        if (core_owner.parent != owner.parent or resources.instance != &owner.parent.instance_storage) return error.Stale;
        if (owner.ring.self_address == 0) owner.ring.open(&owner.backing, value.config, note.point) catch |err| {
            if (err == error.Descriptor or err == error.Retained) self.stop(err); return err;
        };
        const route: display_channel.push.commands.Route = .{ .window = owner.config.index, .head = head };
        var ownership: ?DisplaySubmission = null;
        if (self.display_routes[route.window] != head) {
            if (self.display_images[route.window] != null) return error.Busy;
            ownership = core;
            ownership.?.config.route = route;
            ownership.?.config.ownership_only = true;
            ownership.?.config.preserve_windows = try self.displayPeerWindows(route.window);
            // The separate notifier-backed ownership update initializes this
            // ring first. Its point does not qualify a scanned image.
            core.config.initialize = false;
        }
        core.config.route = route;
        const lut = resources.identityLutControls(head, route.window);
        if (owner.parent.identity_windows & (@as(u8, 1) << @intCast(route.window)) != 0 and lut == null) return error.Busy;
        self.display_work = .{ .core = core, .ownership = ownership, .deadline = deadline,
            .window = .{ .handle = window_handle, .notifier = note,
                .config = .{ .notifier = note.handle, .windows = root.hardware.windows, .initialize = !owner.ring.initialized,
                    .kind = .window, .notifier_offset = offset, .scanout = image, .route = route, .identity_lut = lut } } };
    }
    pub fn displayImageStatus(self: *Owner, root: DisplayEngineHandle, window: u32) !?ActiveDisplayImage {
        _ = try self.findDisplayEngine(root);
        if (window >= self.display_images.len) return error.Bounds;
        return self.display_images[window];
    }
    pub fn takeDisplayLinkFailure(self: *Owner, root: DisplayEngineHandle, window: u32, candidate: u32, plan: boot_mode.Plan) !?DisplayLinkFailure {
        _ = try self.findDisplayEngine(root);
        if (window >= 8 or plan.epoch != self.epoch or plan.window != window) return error.Stale;
        if (self.display_work != null) return error.Busy;
        const failed = self.display_link_failures[window] orelse return null;
        if (failed.candidate != candidate or !std.meta.eql(failed.mode, plan) or failed.receipt == 0 or
            !std.meta.eql(failed.previous, self.display_images[window]) or
            (failed.previous == null and !std.meta.eql(failed.retired, self.display_retired[window]))) return error.Stale;
        self.display_link_failures[window] = null;
        return failed;
    }
    /// Stop the last acknowledged route using NULL ISO and Core interlocks.
    /// Current receiver data is deliberately irrelevant to disabling that
    /// exact old route. Storage remains bound until hardware proves retirement.
    pub fn detachDisplayImage(self: *Owner, core_handle: DisplayChannelHandle, window_handle: DisplayChannelHandle, deadline: u64) !void {
        const window = try self.findDisplayChannel(window_handle);
        _ = window.info() orelse return error.State;
        if (window.config.kind != .window or !self.outputPaused(window.config.index)) return error.State;
        const previous = self.display_images[window.config.index] orelse return error.State;
        const mode = previous.boot_mode orelse return error.State;
        if (previous.core_point == 0 or previous.window_point == 0 or previous.link == null or
            previous.link.?.receipt == 0 or mode.epoch != self.epoch) return error.Stale;
        var core = try self.prepareDisplayCore(core_handle, deadline);
        if (core.config.initialize or window.parent != (try self.findDisplayChannel(core_handle)).parent or
            !window.ring.valid() or !window.ring.initialized or window.ring.pending != null) return error.State;
        const note = self.display_resources_slot.owner.?.publishedNotifier(window_handle.slot) orelse return error.State;
        const offset = try note.nextWindowOffset();
        const route: display_channel.push.commands.Route = .{ .window = window.config.index, .head = previous.head };
        core.config.route = route; core.config.detach_sor = mode.signal.sor;
        core.config.mst_sor_control = try @import("gsp_mst_sor.zig").control(mode, &self.display_images, true);
        core.config.clear_dsc = mode.signal.dp_dsc != null or mode.signal.hdmi_dsc != null;
        self.display_work = .{ .core = core, .deadline = deadline, .detach = previous, .window = .{
            .handle = window_handle, .notifier = note, .config = .{ .kind = .window, .notifier = note.handle,
                .notifier_offset = offset, .windows = core.config.windows, .initialize = !window.ring.initialized,
                .route = route, .detach_sor = mode.signal.sor } } };
        self.display_retired[route.window] = null;
    }
    pub fn validateDisplayDetach(self: *Owner) !void {
        const work = self.display_work orelse return error.State;
        const previous = work.detach orelse return error.State;
        const window = work.window orelse return error.Stale;
        const mode = previous.boot_mode orelse return error.Stale;
        const route: display_channel.push.commands.Route = .{ .window = mode.window, .head = previous.head };
        if (work.core.config.mst_sor_control != try @import("gsp_mst_sor.zig").control(mode, &self.display_images, true) or
            window.config.mst_sor_control != null) return error.Stale;
        if (!self.outputPaused(mode.window) or mode.epoch != self.epoch or mode.window >= 8 or mode.signal.sor >= 8 or
            self.display_images[mode.window] == null or !std.meta.eql(previous, self.display_images[mode.window].?) or
            work.boot_mode != null or work.link != null or work.cursor != null or work.position != null or work.mode_receipt != 0 or
            !std.meta.eql(work.core.config.route, @as(?display_channel.push.commands.Route, route)) or
            !std.meta.eql(window.config.route, work.core.config.route) or window.handle.slot != mode.window + 1 or
            work.core.config.detach_sor != mode.signal.sor or window.config.detach_sor != mode.signal.sor or
            work.core.config.clear_dsc != (mode.signal.dp_dsc != null or mode.signal.hdmi_dsc != null) or window.config.clear_dsc or
            work.core.config.signal != null or window.config.signal != null or window.config.scanout != null or
            work.core.config.cursor_image != null or window.config.cursor_image != null or work.core.config.cursor_usage != 0 or
            work.core.config.initialize or window.config.initialize or window.config.with_position) return error.Stale;
    }
    /// Flip an already CE-completed private image at unchanged mode and
    /// primary position. This emits only Window methods. It does not change
    /// the common shadow binding or reinterpret its CPU-copy queue fence.
    pub fn flipDisplayPresentationImage(self: *Owner, dma: u32, deadline: u64) !void {
        if (self.executionWorkBusy() or self.queued_render != null or (self.direct_work != null and !self.direct_step) or
            self.graph_closing or self.nativeObjectForDisplay() == null) return error.Busy;
        const entry = try self.findPresentationImage(dma);
        const window_index = entry.window.slot - 1;
        const current = self.currentPresentation(window_index) orelse return error.State;
        if (!self.refresh_clocks[window_index].allowFrame(try self.now())) return error.Busy;
        if (self.outputPaused(window_index) or self.displayFlip(window_index) != null or !self.validPresentation(current)) return error.Busy;
        if (self.readyImage(window_index)) |ready| if (ready.image.surface.scanout.?.dma != dma) return error.Busy;
        if (!self.preparedPresentation(entry) or (entry.initial_point == 0 and entry.direct == null) or entry.initial_failure != null) return error.Stale;
        const owner = try self.findDisplayChannel(entry.window);
        const root = owner.parent.info() orelse return error.State;
        const previous = self.display_images[owner.config.index] orelse return error.State;
        const image = entry.surface.scanout.?;
        if (image.dma == previous.image.dma or image.width != previous.image.width or image.height != previous.image.height or
            image.format != previous.image.format or previous.position == null or
            previous.core_point == 0 or previous.window_point == 0 or previous.boot_mode == null or previous.link == null or
            !std.meta.eql(entry.window, current.window)) return error.Unsupported;
        _ = try self.headObservation(previous.head);
        const resources = self.display_resources_slot.owner orelse return error.State;
        const note = resources.publishedNotifier(entry.window.slot) orelse return error.State;
        if (!try resources.imageFinished(entry.window.slot, dma)) return error.Busy;
        const offset = try note.nextWindowOffset();
        if (!owner.ring.valid() or !owner.ring.initialized or owner.ring.pending != null or owner.ring.issued != owner.ring.completed or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        if (self.flip_issued == std.math.maxInt(u64)) return error.Exhausted;
        try self.channel.?.guard(deadline);
        self.flip_issued += 1;
        self.flip_serials[owner.config.index] += 1;
        self.output_frames[owner.config.index].submitted += 1;
        self.display_flips[owner.config.index] = .{ .presentation = entry, .previous = previous, .deadline = deadline,
            .window = .{ .handle = entry.window, .notifier = note, .config = .{ .kind = .window, .notifier = note.handle,
                .notifier_offset = offset, .windows = root.hardware.windows, .initialize = false, .with_core = false,
                .route = .{ .window = owner.config.index, .head = previous.head }, .scanout = image } },
            .receipt = .{ .epoch = self.epoch, .sequence = self.flip_serials[owner.config.index], .head = previous.head, .window = owner.config.index,
                .previous_dma = previous.image.dma, .image_dma = dma, .render_point = entry.initial_point,
                .source_timeline = entry.render_fence.timeline, .source_point = entry.render_fence.point, .direct = entry.direct != null } };
    }
    fn headSource(self: *const Owner, head: u32) !*const @import("gsp_head_events.zig").Head {
        const source = self.head_events orelse return error.Unsupported;
        if (!source.enabled or source.epoch != self.epoch or head >= source.heads.len or
            source.head_mask & (@as(u32, 1) << @intCast(head)) == 0) return error.Stale;
        return &source.heads[head];
    }
    fn headObservation(self: *const Owner, head: u32) !@import("gsp_head_events.zig").Sample {
        return (try self.headSource(head)).snapshot() orelse error.Busy;
    }
    pub fn moveCursor(self: *Owner, handle: DisplayChannelHandle, x: i32, y: i32, deadline: u64) !u64 {
        const owner = try self.findDisplayChannel(handle);
        if (self.cursor_point != null) return error.Busy;
        const current = try self.now();
        if (owner.config.kind != .cursor or owner.info() == null or self.display_work != null or self.display_upload_job != null or self.cursor_upload != null or
            self.initial_image != null or self.graph_closing or self.sequence.self_address != 0 or self.channel == null or
            self.activeChannel() != &self.channel.? or self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        _ = try self.headSource(owner.config.index);
        try self.channel.?.guard(deadline);
        const result = try owner.point.begin(x, y, current, deadline);
        self.cursor_point = handle.slot;
        return result;
    }
    pub fn validateCursorPoint(self: *Owner, owner: *display_channel.Owner, deadline: u64) !void {
        const slot = self.cursor_point orelse return error.State;
        if (slot >= self.display_channels.len or self.display_channels[slot] == null or &self.display_channels[slot].? != owner or
            owner.config.kind != .cursor or owner.config.root.epoch != self.epoch or owner.info() == null or
            !owner.point.valid(deadline) or self.display_work != null or self.display_upload_job != null or self.cursor_upload != null or self.initial_image != null or
            self.graph_closing or self.sequence.self_address != 0 or self.channel == null or self.activeChannel() != &self.channel.? or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Stale;
        _ = try self.headSource(owner.config.index);
        try self.channel.?.guard(deadline);
    }
    fn advanceCursorPoint(self: *Owner, current: u64) !bool {
        const slot = self.cursor_point orelse return false;
        const owner = if (self.display_channels[slot]) |*value| value else return error.Stale;
        const job = owner.point.pending orelse return error.Stale;
        try self.validateCursorPoint(owner, job.deadline);
        if (current >= job.deadline) return error.Timeout;
        const sample = (try self.device.?.readCursorPoint(owner, job.deadline)) orelse return false;
        if (self.display_paused) {
            // Finish only the already published PIO prefix. Its UPDATE
            // drains the owned position; no new cursor request or visibility
            // receipt is created while the output is paused.
            if (job.published and job.next_method < @import("gsp_cursor_pio.zig").methods.len) {
                if (!try @import("gsp_cursor_pio.zig").writable(sample)) return false;
                try owner.point.prepareUpdate(current,job.baseline);
                self.device.?.submitCursorPoint(owner,job.deadline) catch |err| {if(err==error.Busy)return false;return err;};
                return true;
            }
            // PIO drain proves that no position write remains outstanding;
            // it does not fabricate a visible position or a head IRQ.
            if (job.published and !try @import("gsp_cursor_pio.zig").idle(sample)) return false;
            owner.point.pending = null;
            self.cursor_point = null;
            return true;
        }
        const observed = self.headObservation(owner.config.index) catch |err| { if (err == error.Busy) return false; return err; };
        // An electrical IRQ may advance the snapshot after this worker read
        // its clock. Keep the exact PIO prefix until the next worker time;
        // this is neither a deadline failure nor a visibility receipt.
        if (observed.observed_ns > current) return false;
        if (job.next_method < @import("gsp_cursor_pio.zig").methods.len) {
            if (!try @import("gsp_cursor_pio.zig").writable(sample)) return false;
            if (!job.published) try owner.point.prepare(current, observed)
            else try owner.point.prepareUpdate(current, observed);
            self.device.?.submitCursorPoint(owner, job.deadline) catch |err| { if (err == error.Busy) return false; return err; };
            if (owner.point.issued == 1) self.log("NVIDIA cursor-point: first sequence={d} method-prefix={d}/2 free={x} control={x} state={x} x={d} y={d}",
                .{owner.point.issued,owner.point.pending.?.next_method,sample.free,sample.control,sample.state,job.point.x,job.point.y});
            return true;
        }
        if (!try owner.point.observe(sample, observed, current)) return false;
        if (owner.point.issued == 1) self.log("NVIDIA cursor-point: first complete sequence={d} head-IRQ={d} observed={d} update-submitted={d} free={x} control={x} state={x}",
            .{owner.point.issued,observed.sequence,observed.observed_ns,job.update_submitted_ns,sample.free,sample.control,sample.state});
        self.cursor_point = null; return true;
    }
    /// Repeated at the real PUT gate. No caller-selected buffer, timing,
    /// completed CE point, prior display or event generation is trusted.
    pub fn validateDisplayFlip(self: *Owner) !void {
        const current = self.presentation orelse return error.State;
        try self.validateOutputFlip(current.window.slot - 1);
    }
    pub fn displayFlip(self: *Owner, window: u32) ?*DisplayFlip {
        if (window >= self.display_flips.len) return null;
        return if (self.display_flips[window]) |*work| work else null;
    }
    pub fn primaryFlip(self: *Owner) ?*DisplayFlip {
        const current = self.presentation orelse return null;
        return self.displayFlip(current.window.slot - 1);
    }
    pub fn hasDisplayFlips(self: *const Owner) bool {
        for (&self.display_flips) |*slot| if (slot.* != null) return true;
        return false;
    }
    pub fn validateOutputFlip(self: *Owner, window: u32) !void {
        const work = self.displayFlip(window) orelse return error.State;
        const entry = work.presentation;
        const config = work.window.config;
        const image = entry.surface.scanout orelse return error.Stale;
        const route = config.route orelse return error.Stale;
        if (!self.preparedPresentation(entry) or !std.meta.eql(work.window.handle, entry.window) or
            config.kind != .window or config.initialize or config.with_core or config.with_position or config.position != null or config.signal != null or config.detach_sor != null or
            !std.meta.eql(config.scanout, @as(?display_resources.image.Image, image)) or route.window != entry.window.slot - 1 or route.head != work.previous.head or
            route.window != window or work.receipt.epoch != self.epoch or work.receipt.sequence != self.flip_serials[window] or
            work.receipt.sequence == 0 or work.receipt.sequence > self.flip_issued or work.receipt.head != route.head or work.receipt.window != route.window or
            work.receipt.image_dma != image.dma or work.receipt.previous_dma != work.previous.image.dma or work.receipt.render_point != entry.initial_point or
            work.receipt.source_timeline != entry.render_fence.timeline or work.receipt.source_point != entry.render_fence.point or
            (entry.initial_point == 0 and entry.direct == null) or work.receipt.direct != (entry.direct != null) or entry.initial_failure != null or image.dma == work.previous.image.dma or
            image.width != work.previous.image.width or image.height != work.previous.image.height or
            image.format != work.previous.image.format or work.previous.boot_mode == null or work.previous.link == null or work.previous.position == null or
            work.previous.core_point == 0 or work.previous.window_point == 0) return error.Stale;
        const current = self.display_images[route.window] orelse return error.Stale;
        var expected = work.previous;
        if (work.receipt.begun_observed_ns != 0 or work.retiring_activation) {
            expected.image = image;
            expected.window_point = if (work.retiring_activation) work.window.ticket.?.point else work.receipt.window_point;
        }
        if (!std.meta.eql(current, expected)) return error.Stale;
        _ = try self.headSource(route.head);
    }
    /// The adapter owns one CE consumer, with no display or receiver input.
    /// Register only after RM admitted the real class/channel and its memory
    /// epoch. Operations describe executable work, never architecture alone.
    pub fn registerCopyBackend(self: *Owner, handle: ChannelHandle, deadline: u64) !r4os.abi.GfxBackendBinding {
        const fifo = try self.findChannel(handle);
        const info = fifo.info() orelse return error.Busy;
        if (self.copyBusy() or self.graph_closing or self.nativeObject() == null or !fifo.ring.idle()) return error.Busy;
        const va = self.nativeAddressSpace() orelse return error.Busy;
        if (info.config.engine != .copy or !info.config.system_userd or info.config.context.vaspace != va.handle) return error.Binding;
        try self.channel.?.guard(deadline);
        if (self.copy_backend) |backend| {
            if (backend.channel == null or !std.meta.eql(backend.channel.?, handle)) return error.Stale;
            return backend.binding;
        }
        const queue = (if (self.copy_backend) |backend| @as(?r4os.driver_queue.Context, backend.queue) else self.ctx.?.graphicsQueue()) orelse return error.Api;
        if (queue.table.unregister_backend == 0 or queue.table.update_operations == 0) return error.Api;
        const nv = @import("r4nv_binding");
        const details: nv.R4NvDriverProfile = .{ .version = 1, .size = @sizeOf(nv.R4NvDriverProfile), .vendor_id = 0x10de,
            .copy_class = info.config.object_class, .rm_release = nv.rm_release, .command_abi = nv.command_abi, .reserved0 = 0, .reserved1 = 0 };
        var profile: r4os.abi.GfxBackendProfile = .{ .interface_id_lo = nv.backend_v1_header.interface_id_lo,
            .interface_id_hi = nv.backend_v1_header.interface_id_hi, .revision = 1, .data_bytes = @sizeOf(nv.R4NvDriverProfile) };
        @memcpy(profile.data[0..@sizeOf(nv.R4NvDriverProfile)], std.mem.asBytes(&details));
        const registration: r4os.abi.GfxBackendRegistration = .{ .adapter_id = self.adapter_id,
            .milestone = r4os.abi.gfx_queue_milestone_device_execution, .operations = 9, .memory_generation = self.epoch,
            .notify_callback = @intFromPtr(&notifyCopyBackend), .context = @intFromPtr(self) };
        var binding: r4os.abi.GfxBackendBinding = .{};
        var result = queue.registerProfile(&registration, &profile, &binding);
        if (result == r4os.abi.err_no_fn) result = queue.register(&registration, &binding);
        if (result != r4os.abi.gfx_queue_ok and binding.device_generation == 0) return error.Queue;
        // Keep a returned identity even after a malformed/uncertain response.
        // Only the existing quarantine/reset path may retire this backend.
        self.copy_backend = .{ .queue = queue, .binding = binding, .channel = handle };
        if (result != r4os.abi.gfx_queue_ok or binding.version != 1 or binding.size < @sizeOf(r4os.abi.GfxBackendBinding) or
            binding.adapter_id != self.adapter_id or binding.milestone != r4os.abi.gfx_queue_milestone_device_execution or
            binding.device_generation == 0 or binding.reset_generation == 0) { self.stop(error.Descriptor); return error.Descriptor; }
        self.publishArchitecture(&queue, binding, info.config.object_class);
        self.log("NVIDIA device-backend: epoch={d} copy-class={x} operations=copy,copy-rows output-required=no", .{self.epoch,info.config.object_class});
        return binding;
    }
    /// Attach a prepared private image to the adapter's existing queue.
    /// The display transition owner supplies its real CPU shadow; queued
    /// uploads are admitted only while that exact image is active.
    /// Registration alone does not adopt the boot framebuffer or change mode.
    pub fn registerDisplayPresentation(self: *Owner, handle: ChannelHandle, root: DisplayEngineHandle,
        window: DisplayChannelHandle, dma: u32, shadow: r4os.abi.GfxBufferHandle, deadline: u64) !r4os.abi.GfxBackendBinding
    {
        if (self.presentation != null) return self.registerAdditionalPresentation(handle, root, window, dma, shadow, deadline);
        const fifo = try self.findChannel(handle);
        const window_owner = try self.findDisplayChannel(window);
        const engine = try self.findDisplayEngine(root);
        if (self.presentation != null or self.copyBusy() or self.nativeObject() == null or
            self.graph_closing or fifo.info() == null or !fifo.ring.idle() or window_owner.info() == null or window_owner.parent != engine or
            window_owner.config.kind != .window) return error.Busy;
        if (self.display_images[window_owner.config.index] != null) return error.Busy;
        const resources = self.display_resources_slot.owner orelse return error.State;
        const image = resources.publishedImage(window.slot, dma) orelse return error.State;
        const target = resources.publishedStorage(window.slot, dma) orelse return error.State;
        if (fifo.config.context.vaspace != self.nativeAddressSpace().?.handle) return error.Stale;
        try self.channel.?.guard(deadline);
        const memory = self.memory_api orelse return error.Api;
        for (&self.presentation_slots) |*slot| if (slot.* != null) return error.Retained;
        const binding = try self.registerCopyBackend(handle, deadline);
        const backend = &self.copy_backend.?;
        self.presentation_slots[0] = .{ .channel_handle = handle, .root = root, .window = window, .binding = binding };
        const entry = &self.presentation_slots[0].?;
        self.presentation = entry;
        entry.surface.open(memory, shadow, target, image) catch |err| {
            if (entry.surface.failed) self.stop(err) else { self.presentation = null; self.presentation_slots[0] = null; }
            return err;
        };
        const operations = backend.operations | (@as(u64, 1) << r4os.abi.gfx_queue_operation_upload) |
            @as(u64, if (self.graphics_enabled) 1 << r4os.abi.gfx_queue_operation_present else 0);
        const result = backend.queue.updateOperations(&backend.binding, operations);
        if (result != r4os.abi.gfx_queue_ok) {
            if (!entry.surface.closeUnregistered()) { self.stop(error.Retained); return error.Retained; }
            self.presentation = null; self.presentation_slots[0] = null;
            return if (result == r4os.abi.gfx_queue_error_busy) error.Busy else error.Queue;
        }
        backend.operations = operations;
        entry.registered = true;
        entry.pending = backend.pending;
        return entry.binding;
    }
    fn publishArchitecture(self: *Owner, queue: *const r4os.driver_queue.Context, binding: r4os.abi.GfxBackendBinding, copy_class: u32) void {
        const held = self.reservation orelse return;
        const captured = held.display orelse return;
        const pci = if (captured.snapshot) |*value| value else return;
        const chip = captured.chip orelse return;
        const topology = self.post.snapshot() orelse return;
        if (self.post.epoch != self.epoch) return;
        const memory = if (self.static_info) |*value| value else return;
        const va = self.nativeAddressSpace() orelse return;
        const properties = @import("gsp_architecture.zig").describe(pci, chip.id, topology, memory, va.*, self.epoch, copy_class) catch |err| {
            self.log("NVIDIA architecture: unavailable reason={s}", .{@errorName(err)}); return;
        };
        const result = queue.publishProperties(&binding, &properties);
        if (result != r4os.abi.gfx_queue_ok) self.log("NVIDIA architecture: unavailable result={d}", .{result});
    }
    fn registerAdditionalPresentation(self: *Owner, handle: ChannelHandle, root: DisplayEngineHandle,
        window: DisplayChannelHandle, dma: u32, shadow: r4os.abi.GfxBufferHandle, deadline: u64) !r4os.abi.GfxBackendBinding
    {
        const fifo = try self.findChannel(handle);
        const channel = try self.findDisplayChannel(window);
        const engine = try self.findDisplayEngine(root);
        const primary = self.presentation orelse return error.State;
        const backend = self.copy_backend orelse return error.State;
        if (channel.config.kind != .window or self.currentPresentation(channel.config.index) != null or
            self.copyBusy() or self.nativeObject() == null or self.graph_closing or !self.validPresentation(primary) or
            fifo.info() == null or !fifo.ring.idle() or channel.info() == null or channel.parent != engine or
            !std.meta.eql(handle, primary.channel_handle) or !std.meta.eql(root, primary.root)) return error.Busy;
        const claim = self.output_claims[channel.config.index] orelse return error.State;
        if (claim.window != channel.config.index or self.display_images[claim.window] != null) return error.Stale;
        const resources = self.display_resources_slot.owner orelse return error.State;
        const image = resources.publishedImage(window.slot, dma) orelse return error.Stale;
        const storage = resources.publishedStorage(window.slot, dma) orelse return error.Stale;
        const memory = self.memory_api orelse return error.Api;
        const index: usize = blk: {
            for (&self.presentation_slots, 0..) |*slot, i| if (slot.* == null) break :blk i;
            return error.Busy;
        };
        try self.channel.?.guard(deadline);
        self.presentation_slots[index] = .{ .channel_handle = handle, .root = root, .window = window,
            .binding = backend.binding, .registered = true };
        const entry = &self.presentation_slots[index].?;
        entry.surface.open(memory, shadow, storage, image) catch |err| {
            if (entry.surface.failed) self.stop(err) else self.presentation_slots[index] = null;
            return err;
        };
        // The one adapter backend consumes all output-targeted queue jobs.
        // Registering an additional consumer would create a competing queue.
        self.additional_presentations[claim.window] = entry;
        return backend.binding;
    }
    fn notifyCopyBackend(raw: usize) callconv(.c) i32 {
        if (raw == 0) return -1;
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw or self.failure != null) return -1;
        const backend = if (self.copy_backend) |*value| value else return -1;
        // Already under the serialized DriverWork owner. Pacing owns waits.
        backend.pending = true;
        self.native_queues.wake();
        if (self.queued_native) |work| work.waited = false;
        if (self.presentation) |entry| entry.pending = true;
        if (self.device.?.owner) |io| if (io.wake_work) |wake| wake(io.context);
        return 0;
    }
    fn presentationValid(self: *Owner) bool {
        return self.validPresentation(self.presentation orelse return false);
    }
    pub fn currentPresentation(self: *Owner, window: u32) ?*Presentation {
        if (window >= 8) return null;
        if (self.presentation) |entry| if (entry.window.slot == window + 1) return entry;
        return self.additional_presentations[window];
    }
    pub fn outputPaused(self: *const Owner, window: u32) bool {
        if (window >= 8) return true;
        if (self.presentation) |entry| if (entry.window.slot == window + 1) return self.display_paused;
        return self.additional_paused[window];
    }
    pub fn pauseOutput(self: *Owner, window: u32, paused: bool) !void {
        if (window >= 8 or self.currentPresentation(window) == null) return error.State;
        if (!paused and self.output_faults[window] != null) return error.Retained;
        if (self.presentation) |entry| if (entry.window.slot == window + 1) { self.display_paused = paused; return; };
        self.additional_paused[window] = paused;
    }
    pub fn outputRestoring(self: *const Owner, window: u32) bool {
        if (window >= 8) return false;
        if (self.presentation) |entry| if (entry.window.slot == window + 1) return self.display_restoring;
        return self.additional_restoring[window];
    }
    pub fn restoreOutput(self: *Owner, window: u32, restoring: bool) !void {
        if (window >= 8 or self.currentPresentation(window) == null) return error.State;
        if (self.presentation) |entry| if (entry.window.slot == window + 1) { self.display_restoring = restoring; return; };
        self.additional_restoring[window] = restoring;
    }
    /// One common mode queue serves the adapter. Keep its canonical job in
    /// one resident mailbox until the matching output owner consumes it.
    pub fn takeOutputMode(self: *Owner, api: r4os.driver_outputs.Context, backend: r4os.abi.GfxBackendBinding,
        output: r4os.abi.GfxOutputId) !?r4os.abi.GfxDriverModeJob
    {
        if (self.mode_mailbox == null) {
            var job: r4os.abi.GfxDriverModeJob = .{};
            const status = api.takeMode(&backend, &job);
            if (status == 0) return null;
            if (status != r4os.abi.gfx_output_ok) return error.ModeApi;
            self.mode_mailbox = job;
        }
        const job = self.mode_mailbox.?;
        if (!std.meta.eql(job.assignment.output, output)) return null;
        self.mode_mailbox = null;
        return job;
    }
    pub fn hasOtherOutput(self: *Owner, window: u32) bool {
        for (0..8) |index| {
            if (index == window or self.outputPaused(@intCast(index)) or self.presentation_targets[index] == null) continue;
            if (self.currentPresentation(@intCast(index)) != null and self.display_images[index] != null) return true;
        }
        return false;
    }
    pub fn directOutputAvailable(self: *Owner, window: u32) bool {
        return self.direct_enabled and self.preparing_outputs == 0 and self.presentation != null and
            self.presentation.?.window.slot == window + 1 and !self.hasOtherOutput(window);
    }
    fn faultOutput(self: *Owner, window: u3, err: anyerror) void {
        if (self.output_faults[window] != null) return;
        self.output_faults[window] = err;
        if (self.presentation != null and self.presentation.?.window.slot == @as(u32, window) + 1)
            self.display_paused = true else self.additional_paused[window] = true;
        self.log("NVIDIA output-stall: window={d} reason={s} pending-Window=retained other-outputs=running", .{ window, @errorName(err) });
    }
    pub fn readyImage(self: *const Owner, window: u32) ?ReadyImage {
        if (window >= 8) return null;
        if (self.presentation) |entry| if (entry.window.slot == window + 1) return self.frame_ready;
        return self.additional_ready[window];
    }
    fn setReadyImage(self: *Owner, window: u32, ready: ?ReadyImage) !void {
        if (window >= 8 or (if (ready) |value| value.image.window.slot != window + 1 else false)) return error.Stale;
        if (self.presentation) |entry| if (entry.window.slot == window + 1) { self.frame_ready = ready; return; };
        self.additional_ready[window] = ready;
    }
    /// Called with the identity returned by common registration/publication,
    /// after this exact head has a completed physical mode and image.
    pub fn bindPresentationTarget(self: *Owner, window: u32, target: r4os.abi.GfxOutputTarget) !void {
        const entry = self.currentPresentation(window) orelse return error.Stale;
        const image = self.display_images[window] orelse return error.Stale;
        const mode = image.boot_mode orelse return error.Stale;
        if (!self.validPresentation(entry) or target.version != 1 or target.size != @sizeOf(r4os.abi.GfxOutputTarget) or
            target.reserved0 != 0 or target.adapter_id != entry.binding.adapter_id or target.device_generation != entry.binding.device_generation or
            target.connector_id != mode.signal.display_id or target.connection_generation == 0 or target.display_generation == 0 or
            target.head_id != image.head) return error.Stale;
        self.presentation_targets[window] = target;
    }
    pub fn presentationForJob(self: *Owner, job: r4os.abi.GfxDriverJob) !*Presentation {
        const a = r4os.abi;
        // Original primary uploads and older queue prefixes have no target.
        // A nonempty tail must always match a complete registered identity.
        if (std.meta.eql(job.display_target, a.GfxOutputTarget{})) return self.presentation orelse error.State;
        if (job.size < @offsetOf(a.GfxDriverJob, "producer_kind")) return error.Stale;
        for (&self.presentation_targets, 0..) |*slot, window| if (slot.*) |target| {
            if (std.meta.eql(target, job.display_target)) return self.currentPresentation(@intCast(window)) orelse error.Stale;
        };
        return error.Stale;
    }
    fn copyPresentation(self: *Owner, work: *const CopyJob) !*Presentation {
        if (!work.presentation or work.output_window == null) return error.State;
        const entry = try self.presentationForJob(work.job);
        if (entry.window.slot != @as(u32, work.output_window.?) + 1) return error.Stale;
        return entry;
    }
    fn selectPresentation(self: *Owner, entry: *Presentation) void {
        if (self.presentation) |primary| {
            if (entry.window.slot == primary.window.slot) { self.presentation = entry; return; }
        } else { self.presentation = entry; return; }
        self.additional_presentations[entry.window.slot - 1] = entry;
    }
    fn validPresentation(self: *Owner, entry: *Presentation) bool {
        if (!self.preparedPresentation(entry)) return false;
        const channel = self.findDisplayChannel(entry.window) catch return false;
        const active = self.display_images[channel.config.index] orelse return false;
        return (entry.initial_point != 0 or (if (entry.direct) |direct| direct.handed_off else false)) and std.meta.eql(active.image, entry.surface.scanout.?);
    }
    fn presentationPrepared(self: *Owner) bool {
        return self.preparedPresentation(self.presentation orelse return false);
    }
    fn preparedPresentation(self: *Owner, entry: *Presentation) bool {
        if (self.presentationIndex(entry) == null or entry.retiring or !entry.registered or !entry.surface.valid() or self.copy_backend == null or
            !std.meta.eql(entry.binding, self.copy_backend.?.binding)) return false;
        const resources = self.display_resources_slot.owner orelse return false;
        const channel = self.findDisplayChannel(entry.window) catch return false;
        const root = self.findDisplayEngine(entry.root) catch return false;
        const value = entry.surface.scanout.?;
        if (entry.direct) |direct| {
            const storage = entry.surface.target orelse return false;
            if (storage.access != 0 or !std.meta.eql(storage.info().?.reference.buffer, direct.job.source_buffer) or
                direct.job.operation != r4os.abi.gfx_queue_operation_direct_present or !std.meta.eql(entry.render_fence, direct.job.fence)) return false;
        }
        return channel.info() != null and channel.parent == root and
            std.meta.eql(resources.publishedImage(entry.window.slot, value.dma), value) and
            resources.publishedStorage(entry.window.slot, value.dma) == entry.surface.target;
    }
    fn presentationIndex(self: *Owner, entry: *Presentation) ?usize {
        for (&self.presentation_slots, 0..) |*slot, i| if (slot.*) |*value| if (value == entry) return i;
        return null;
    }
    fn findPresentationImage(self: *Owner, dma: u32) !*Presentation {
        _ = try self.now();
        for (&self.presentation_slots) |*slot| if (slot.*) |*entry| if (entry.surface.scanout) |image| {
            if (image.dma == dma) return entry;
        };
        return error.Stale;
    }
    pub fn presentationImageWindow(self: *Owner, dma: u32) !u32 {
        return (try self.findPresentationImage(dma)).window.slot - 1;
    }
    /// The common worker lends a full driver reference. Import a separate
    /// alias; ownership of the supplied reference never transfers to NVIDIA.
    /// Stable slots keep present.Owner and its GPU-use pointers immovable.
    pub fn prepareDisplayPresentationImage(self: *Owner, dma: u32, shadow: r4os.abi.GfxBufferReference, deadline: u64) !void {
        return self.preparePresentationImage(self.presentation orelse return error.State, dma, shadow, deadline, false);
    }
    pub fn prepareDisplayFrameImage(self: *Owner, dma: u32, deadline: u64) !void {
        const current = self.presentation orelse return error.State;
        return self.prepareOutputFrameImage(current.window.slot - 1, dma, deadline);
    }
    pub fn prepareOutputFrameImage(self: *Owner, window: u32, dma: u32, deadline: u64) !void {
        const current = self.currentPresentation(window) orelse return error.State;
        return self.preparePresentationImage(current, dma, current.surface.shadow, deadline, true);
    }
    pub fn prepareOutputPresentationImage(self: *Owner, window: u32, dma: u32, shadow: r4os.abi.GfxBufferReference, deadline: u64) !void {
        return self.preparePresentationImage(self.currentPresentation(window) orelse return error.State, dma, shadow, deadline, false);
    }
    pub fn prepareDirectImage(self: *Owner, dma: u32, job: r4os.abi.GfxDriverJob, deadline: u64) !void {
        if (!self.direct_step or self.direct_work == null or job.operation != r4os.abi.gfx_queue_operation_direct_present) return error.State;
        try self.prepareDisplayFrameImage(dma, deadline);
        const entry = try self.findPresentationImage(dma);
        entry.direct = .{ .job = job }; entry.render_fence = job.fence;
        self.frames_acquired +|= 1; self.frames_rendered +|= 1;
        self.output_frames[entry.window.slot - 1].acquired +|= 1;
        self.output_frames[entry.window.slot - 1].rendered +|= 1;
    }
    pub fn directPresentation(self: *Owner, dma: u32) !*Presentation { return self.findPresentationImage(dma); }
    pub fn unregisterDirectImage(self: *Owner, dma: u32) !void {
        if (!self.direct_step or self.direct_work == null) return error.State;
        const entry = try self.findPresentationImage(dma);
        if (entry.direct == null or self.currentPresentation(entry.window.slot - 1) == entry or self.hasDisplayFlips() or self.display_work != null) return error.Busy;
        for (&self.display_images) |active| if (active) |value| if (value.image.dma == dma) return error.Busy;
        if (!try self.display_resources_slot.owner.?.imageFinished(entry.window.slot, dma)) return error.Busy;
        const index = self.presentationIndex(entry) orelse return error.Stale;
        // Its SYSTEM shadow is shared with the private composition pool.
        // Those mappings belong to that pool and survive this direct image.
        if (!entry.surface.closeUnregistered()) return error.Retained;
        self.presentation_slots[index] = null;
    }
    fn preparePresentationImage(self: *Owner, current: *Presentation, dma: u32, shadow: r4os.abi.GfxBufferReference, deadline: u64, frame: bool) !void {
        _ = try self.now();
        const headless = self.outputPaused(current.window.slot - 1) and self.outputRestoring(current.window.slot - 1) and !frame and
            self.preparedPresentation(current) and self.display_images[current.window.slot - 1] == null and
            self.display_retired[current.window.slot - 1] != null;
        if ((!self.validPresentation(current) and !headless) or self.copyBusy() or self.nativeObject() == null or self.graph_closing) return error.Busy;
        if (shadow.version != 1 or shadow.size < @sizeOf(r4os.abi.GfxBufferReference) or shadow.flags != 0 or shadow.reserved0 != 0 or
            shadow.reference.id == 0 or shadow.reference.generation == 0 or shadow.reference.reserved0 != 0 or
            shadow.buffer.id == 0 or shadow.buffer.generation == 0 or shadow.buffer.reserved0 != 0 or
            std.meta.eql(shadow.buffer, current.surface.shadow.buffer) != frame) return error.Descriptor;
        const index: usize = blk: {
            for (&self.presentation_slots, 0..) |*slot, i| if (slot.* == null) break :blk i;
            return error.Busy;
        };
        const resources = self.display_resources_slot.owner orelse return error.State;
        const image = resources.publishedImage(current.window.slot, dma) orelse return error.Stale;
        const target = resources.publishedStorage(current.window.slot, dma) orelse return error.Stale;
        if (dma == current.surface.scanout.?.dma) return error.Stale;
        if (frame and (image.width != current.surface.descriptor.width or image.height != current.surface.descriptor.height or
            image.format != current.surface.scanout.?.format)) return error.Descriptor;
        try self.channel.?.guard(deadline);
        self.presentation_slots[index] = .{ .channel_handle = current.channel_handle, .root = current.root,
            .window = current.window, .binding = current.binding, .registered = true };
        const entry = &self.presentation_slots[index].?;
        entry.surface.open(current.surface.memory.?, shadow.reference, target, image) catch |err| {
            if (entry.surface.failed) self.stop(err) else self.presentation_slots[index] = null;
            return err;
        };
        if (!std.meta.eql(entry.surface.shadow.buffer, shadow.buffer)) {
            if (!entry.surface.closeUnregistered()) { self.stop(error.Retained); return error.Retained; }
            self.presentation_slots[index] = null; return error.Stale;
        }
    }
    /// Select only an already acknowledged physical image. The former slot
    /// remains alive for confirmation/rollback; this does not free storage.
    pub fn selectDisplayPresentationImage(self: *Owner, dma: u32) !void {
        const entry = try self.findPresentationImage(dma);
        if (self.copyBusy()) return error.Busy;
        if (!self.preparedPresentation(entry) or entry.initial_point == 0 or entry.initial_failure != null) return error.Stale;
        const active = self.display_images[entry.window.slot - 1] orelse return error.State;
        if (!std.meta.eql(active.image, entry.surface.scanout.?) or active.core_point == 0 or active.window_point == 0) return error.Stale;
        const old = self.currentPresentation(entry.window.slot - 1);
        const previous = if (old) |value| value.surface.scanout.?.dma else 0;
        if (old) |value| if (value != entry) { entry.pending = entry.pending or value.pending; value.pending = false; };
        self.selectPresentation(entry);
        self.log("NVIDIA gsp-present-image: selected={d} previous={d} size={d}x{d} core={d} window={d} old=retained",
            .{dma, previous, active.image.width, active.image.height, active.core_point, active.window_point});
    }
    /// Select the common owner's retained CPU image while the physical head
    /// is stopped. Every published image in that head must be FINISHED; this
    /// does not manufacture a visible image or release any reference.
    pub fn selectHeadlessImage(self: *Owner, dma: u32) !void {
        const entry = try self.findPresentationImage(dma);
        if (!self.outputPaused(entry.window.slot - 1) or self.copyBusy() or !self.preparedPresentation(entry)) return error.Busy;
        const retired = self.display_retired[entry.window.slot - 1] orelse return error.State;
        if (retired.epoch != self.epoch or retired.core_point == 0 or retired.window_point == 0 or
            self.display_images[entry.window.slot - 1] != null) return error.Stale;
        const resources = self.display_resources_slot.owner orelse return error.State;
        for (&self.presentation_slots) |*slot| if (slot.*) |*image| {
            if (image.window.slot == entry.window.slot and !try resources.imageFinished(entry.window.slot, image.surface.scanout.?.dma)) return error.Busy;
        };
        if (self.currentPresentation(entry.window.slot - 1)) |old| if (old != entry) {
            entry.pending = entry.pending or old.pending; old.pending = false;
        };
        self.selectPresentation(entry);
    }
    /// Bounded retirement: drain all mappings of the inactive private shadow
    /// through real RM cleanup before releasing its owned import. The separate
    /// RAMHT/native image then follows removeDisplayImage. No caller BO release.
    pub fn retireDisplayPresentationImage(self: *Owner, dma: u32, deadline: u64) !bool {
        const entry = try self.findPresentationImage(dma);
        // Direct sources share their shadow with the composition pool. Only
        // advanceDirect may remove their DMA context and retire their fence.
        if (entry.direct != null) return error.Busy;
        if (self.currentPresentation(entry.window.slot - 1) == entry or self.copyBusy() or self.hasQueuedWork() or self.graph_closing) return error.Busy;
        if (self.readyImage(entry.window.slot - 1)) |ready| if (ready.image == entry) return error.Busy;
        const resources = self.display_resources_slot.owner orelse return error.State;
        for (&self.display_images) |active| if (active) |image| if (image.image.dma == dma) return error.Busy;
        if (!try resources.imageFinished(entry.window.slot, dma)) return error.Busy;
        const index = self.presentationIndex(entry) orelse return error.Stale;
        entry.retiring = true;
        for (self.buffers.items(), 0..) |*slot, i| if (slot.owner) |owner| {
            if (!std.meta.eql(owner.source.buffer, entry.surface.shadow.buffer)) continue;
            if (self.buffer_active != null) return false;
            try self.retireBuffer(.{ .epoch = self.epoch, .serial = slot.serial, .slot = @intCast(i) }, deadline, true);
            return false;
        };
        if (self.buffer_active != null) return false; // The exchange must be handed back, too.
        if (!entry.surface.closeUnregistered()) { self.stop(error.Retained); return error.Retained; }
        self.presentation_slots[index] = null;
        self.log("NVIDIA gsp-present-image: retired={d} shadow=unmapped,import-released scanout=retained", .{dma});
        return true;
    }
    /// Retained queue work needs polling between its hardware sub-operations,
    /// too. A completed CE packet does not make the enclosing GR job idle.
    /// Read only under the lifecycle owner; this pacing hint grants no receipt.
    pub fn workPolling(self: *const Owner) bool {
        return self.sequence.self_address != 0 or self.hasQueuedWork() or self.queued_render != null or self.queued_native != null or
            (if (self.copy_backend) |backend| backend.pending else false) or
            self.copy_job != null or self.graphics_work != null or self.graphics_upload != null or
            self.batch_work != null or self.display_upload_job != null or self.initial_image != null or
            self.cursor_upload != null or self.native_copy.probe.busy();
    }
    fn executionWorkBusy(self: *const Owner) bool { return self.native_copy.probe.busy() or self.batch_work != null or self.power_active or self.graphics_upload != null or self.graphics_work != null or self.copy_job != null or self.display_upload_job != null or self.display_work != null or self.initial_image != null or self.mode_control_active or self.cursor_upload != null or self.audio_work != null or self.monitor_work != null or self.sor_work != null; }
    fn engineWorkBusy(self: *const Owner) bool { return self.executionWorkBusy() or self.hasDisplayFlips(); }
    fn deviceWorkBusy(self: *const Owner) bool { return self.engineWorkBusy() or self.queued_render != null; }
    fn copyBusy(self: *const Owner) bool { return self.deviceWorkBusy() or self.frame_ready != null or (self.direct_work != null and !self.direct_step); }
    fn overlapFlip(self: *const Owner) bool {
        var found = false;
        for (&self.display_flips, 0..) |*slot, window| if (slot.*) |*work| {
            if (!work.ordinary or (self.output_faults[window] == null and work.window.phase != .submitted and work.window.phase != .complete)) return false;
            found = true;
        };
        return found;
    }
    fn copyAdmissionBusy(self: *const Owner) bool {
        return self.executionAdmissionBusy() or self.queued_render != null or self.queued_native != null;
    }
    fn executionAdmissionBusy(self: *const Owner) bool {
        return self.native_copy.probe.busy() or self.batch_work != null or self.power_active or self.powerStopping() or self.direct_work != null or self.cursor_reserving or self.graphics_upload != null or self.graphics_work != null or self.copy_job != null or self.display_upload_job != null or self.display_work != null or self.initial_image != null or self.cursor_upload != null or self.audio_work != null or self.monitor_work != null or self.sor_work != null or
            self.mode_control_active or (self.hasDisplayFlips() and !self.overlapFlip());
    }
    // Context/FIFO/buffer owners may temporarily hold RM without submitting
    // GPU work. Command admission must wait for their exact handback before
    // looking up the hidden address space or guarding the main exchange.
    fn commandExchangeBusy(self: *Owner) bool {
        const channel = if (self.channel) |*value| value else return true;
        return self.sequence.self_address != 0 or self.activeChannel() != channel or
            channel.phase != .idle or channel.pending != null or channel.in_lockdown;
    }
    pub fn privateClearAdmissionBusy(self: *const Owner) bool {
        return self.executionAdmissionBusy() or self.hasDisplayFlips() or self.hasQueuedWork() or self.graph_closing or
            self.fifo_active != null or self.context_active != null or self.native_active != null or self.buffer_active != null or
            self.virtuals.active_range != null or self.sequence.self_address != 0 or self.channel == null or self.channel.?.phase != .idle or
            self.channel.?.pending != null or self.outputs.active();
    }
    pub fn cursorWorkAvailable(self: *Owner) bool {
        return !self.copyBusy() and self.cursor_point == null and self.nativeObject() != null and !self.graph_closing;
    }
    fn retiredMonitorPlan(self: *Owner, window: u32) !@import("gsp_monitor_power.zig").Plan {
        if (window >= 8 or !self.outputPaused(window) or self.display_images[window] != null) return error.State;
        const retired = self.display_retired[window] orelse return error.State;
        const mode = retired.image.boot_mode orelse return error.State;
        const link = retired.image.link orelse return error.State;
        if (retired.epoch != self.epoch or mode.epoch != self.epoch or mode.window != window or
            retired.core_point == 0 or retired.window_point == 0 or !link.complete() or
            !std.meta.eql(mode, link.plan.mode) or self.display_object == null or
            !std.meta.eql(link.plan.object, self.display_object.?)) return error.Stale;
        // Each MST stream was already retired with its ACT/branch receipts.
        // Never write D3 or main-link-off to a root that may have live peers.
        if (link.mst != null and retired.link_stop_receipt == 0) return error.Stale;
        return .{ .object = link.plan.object, .mode = mode,
            .kind = if (link.mst != null) .stream_only else if (link.dp != null) .dp_sst else .digital,
            .sink_control = if (link.mst != null) false else if (link.dp) |dp| dp.sink.revision >= 0x11 else true };
    }
    fn boundMonitorPlan(self: *Owner, window: u32) !@import("gsp_monitor_power.zig").Plan {
        if (window >= 8 or !self.outputPaused(window) or self.display_retired[window] != null) return error.State;
        const image = self.display_images[window] orelse return error.State;
        const mode = image.boot_mode orelse return error.State;
        const link = image.link orelse return error.State;
        if (mode.epoch != self.epoch or mode.window != window or image.head != mode.head or
            image.core_point == 0 or image.window_point == 0 or !link.complete() or
            link.dp != null or link.mst != null or !std.meta.eql(mode, link.plan.mode) or
            self.display_object == null or !std.meta.eql(link.plan.object, self.display_object.?)) return error.Stale;
        // Digital RM power needs the currently bound head. This control is
        // not a DMA retirement receipt; hotplug still completes exact NULL
        // Core/Window/ARM retirement before publishing screen-off.
        return .{ .object = link.plan.object, .mode = mode, .kind = .digital,
            .sink_control = true, .bound_paused = true };
    }
    fn digitalMonitorSleeping(self: *const Owner, plan: display_link.Plan) bool {
        const mode = plan.mode;
        if (mode.window >= 8 or mode.displayPort() or mode.signal.mst != null) return false;
        const sleeping = self.digital_monitor_sleep[mode.window] orelse return false;
        return sleeping.receipt != 0 and mode.epoch == self.epoch and sleeping.object.epoch == self.epoch and
            std.meta.eql(sleeping.object, plan.object) and sleeping.display_id == mode.signal.display_id and
            sleeping.head == mode.head and sleeping.sor == mode.signal.sor;
    }
    pub noinline fn validateDigitalWakeBinding(self: *Owner, window: u32) !void {
        const work = if (self.display_work) |*value| value else return error.State;
        const link = if (work.link) |*value| value else return error.State;
        const part = if (work.ownership) |*value| value else return error.State;
        const old = try self.retiredMonitorPlan(window);
        if (!work.wake_before_link or work.wake_receipt != 0 or work.detach != null or work.cursor != null or
            work.refresh != null or work.link_restore != null or work.link_stop != null or self.displayWorkObsolete() or
            !self.digitalMonitorSleeping(link.plan) or old.kind != .digital or
            !std.meta.eql(old.object, link.plan.object) or old.mode.head != link.plan.mode.head or
            old.mode.signal.display_id != link.plan.mode.signal.display_id or old.mode.signal.sor != link.plan.mode.signal.sor or
            link.phase != .before_scanout or link.pending or link.mutated or link.last_receipt != 0 or
            !part.config.ownership_only or
            !std.meta.eql(part.handle, work.core.handle) or !std.meta.eql(part.config.signal, work.core.config.signal) or
            !std.meta.eql(part.config.route, work.core.config.route) or
            work.core.phase != .prepare or work.core.ticket != null or work.window == null or
            work.window.?.phase != .prepare or work.window.?.ticket != null or work.position == null or
            work.position.?.phase != .prepare or work.position.?.ticket != null) return error.Stale;
        try self.validateDisplayLink();
    }
    noinline fn pendingMonitorPlan(self: *Owner, window: u32) !@import("gsp_monitor_power.zig").Plan {
        try self.validateDigitalWakeBinding(window);
        const work = &self.display_work.?;
        const link = &work.link.?;
        const part = &work.ownership.?;
        if (part.phase != .complete or part.ticket == null) return error.Stale;
        const core = try self.findDisplayChannel(part.handle);
        if (core.ring.pending != null or core.ring.completed != part.ticket.?.point or
            part.notifier.phase != .complete or part.notifier.point != part.ticket.?.point or
            self.display_routes[window] != link.plan.mode.head) return error.Stale;
        return .{ .object = link.plan.object, .mode = link.plan.mode, .kind = .digital,
            .sink_control = true, .bound_paused = true, .pending_head = true };
    }
    fn beginPendingMonitorWake(self: *Owner, window: u32, deadline: u64) !u64 {
        if (self.commandExchangeBusy() or self.monitor_work != null or self.audio_work != null or
            self.cursor_point != null or self.cursor_upload != null or self.hasDisplayFlips() or self.graph_closing)
            return error.Busy;
        if (deadline <= try self.now() or self.monitor_sequence == std.math.maxInt(u64)) return error.Deadline;
        const plan = try self.pendingMonitorPlan(window);
        const work = try @import("gsp_monitor_power.zig").Work.init(plan, true, self.monitor_sequence + 1, deadline);
        self.monitor_sequence += 1; self.monitor_work = work;
        errdefer self.monitor_work = null;
        try self.validateMonitorPower();
        return self.monitor_sequence;
    }
    pub fn retryPendingMonitorWake(self: *Owner, window: u32, deadline: u64) !boot_mode.Plan {
        if (self.commandExchangeBusy() or self.monitor_work != null) return error.Busy;
        const plan = try self.pendingMonitorPlan(window);
        const work = &self.display_work.?;
        if (work.wake_failure == null or work.wake_sequence == 0 or deadline <= try self.now()) return error.State;
        // Only the new public intent reaches this operation. The completed
        // ownership receipt is retained; no Core command is replayed.
        work.deadline = deadline; work.wake_sequence = 0; work.wake_failure = null;
        return plan.mode;
    }
    pub fn beginBoundMonitorPower(self: *Owner, window: u32, on: bool, deadline: u64) !u64 {
        if (!self.cursorWorkAvailable() or self.channel.?.phase != .idle) return error.Busy;
        if (deadline <= try self.now() or self.monitor_sequence == std.math.maxInt(u64)) return error.Deadline;
        const plan = try self.boundMonitorPlan(window);
        const work = try @import("gsp_monitor_power.zig").Work.init(plan, on, self.monitor_sequence + 1, deadline);
        self.monitor_sequence += 1; self.monitor_work = work;
        errdefer self.monitor_work = null;
        try self.validateMonitorPower();
        return self.monitor_sequence;
    }
    pub fn beginMonitorPower(self: *Owner, window: u32, on: bool, deadline: u64) !u64 {
        if (!self.cursorWorkAvailable() or self.channel.?.phase != .idle) return error.Busy;
        if (deadline <= try self.now() or self.monitor_sequence == std.math.maxInt(u64)) return error.Deadline;
        const plan = try self.retiredMonitorPlan(window);
        const work = try @import("gsp_monitor_power.zig").Work.init(plan, on, self.monitor_sequence + 1, deadline);
        self.monitor_sequence += 1;
        self.monitor_work = work;
        errdefer self.monitor_work = null;
        try self.validateMonitorPower();
        return self.monitor_sequence;
    }
    pub fn validateMonitorPower(self: *Owner) !void {
        const work = self.monitor_work orelse return error.State;
        if (self.failure != null or self.graph_closing or self.channel == null or self.activeChannel() != &self.channel.? or
            (!work.plan.pending_head and self.display_work != null) or self.hasDisplayFlips() or self.cursor_point != null or self.audio_work != null or
            !std.meta.eql(work.plan, if (work.plan.pending_head) try self.pendingMonitorPlan(work.plan.mode.window)
                else if (work.plan.bound_paused) try self.boundMonitorPlan(work.plan.mode.window)
                else try self.retiredMonitorPlan(work.plan.mode.window))) return error.Stale;
    }
    fn advanceMonitorPower(self: *Owner, current: u64) !Progress {
        const control = @import("gsp_monitor_power.zig");
        const work = &self.monitor_work.?;
        const channel = &self.channel.?;
        try self.validateMonitorPower();
        if (current >= work.deadline) return error.Timeout;
        if (current < work.not_before) return .idle;
        if (work.stage == .complete) {
            if (work.plan.kind == .digital) {
                if (!work.on) self.digital_monitor_sleep[work.plan.mode.window] = .{
                    .object = work.plan.object, .display_id = work.plan.mode.signal.display_id,
                    .head = work.plan.mode.head, .sor = work.plan.mode.signal.sor, .receipt = work.receipt,
                } else if (!work.plan.pending_head) self.digital_monitor_sleep[work.plan.mode.window] = null;
            }
            self.log("NVIDIA screen-control: on={} bound={} head={d} pending={} status=0 receipt={d}",
                .{work.on, work.plan.bound_paused, work.plan.mode.head, work.plan.pending_head, work.receipt});
            self.monitor_result = .{ .sequence = work.sequence, .on = work.on, .receipt = work.receipt };
            self.monitor_work = null;
            return .progress;
        }
        if (!work.pending) {
            work.length = try work.encode(&work.request);
            try channel.begin(control.function, work.request[0..work.length], work.deadline);
            work.attempts += 1;
            work.pending = true;
            return .progress;
        }
        if (try channel.poll(work.deadline)) |dispatch| {
            if (!dispatch.response) { try self.notification(channel, dispatch, current); return .progress; }
            const failure: ?anyerror = blk: {
                work.consume(dispatch.record, current, dispatch.ticket.serial) catch |err| {
                    if (err == error.RmRejected or err == error.Aux or err == error.RetryExhausted) break :blk err;
                    return err;
                };
                break :blk null;
            };
            const status: ?u32 = if (failure != null and dispatch.record.payload.len >= 16)
                std.mem.readInt(u32, dispatch.record.payload[12..16], .little) else null;
            try channel.complete(dispatch.ticket);
            work.pending = false;
            if (failure) |reason| {
                self.log("NVIDIA screen-control: on={} cmd={x} client={x} object={x} display={x} head={d} forced={} bound={} rpc={x} status={?x} error={s}",
                    .{ work.on, std.mem.readInt(u32, work.request[8..12], .little), work.plan.object.client,
                        work.plan.object.display, work.plan.mode.signal.display_id, work.plan.mode.head,
                        work.plan.force_monitor_state, work.plan.bound_paused, dispatch.record.rpc.result, status, @errorName(reason) });
                self.monitor_result = .{ .sequence = work.sequence, .on = work.on,
                    .receipt = dispatch.ticket.serial, .failure = reason };
                self.monitor_work = null;
            }
            return .progress;
        }
        return if (channel.phase == .waiting) .idle else .progress;
    }
    pub fn beginDisplayAudio(self: *Owner, plan: display_audio.Plan, operation: display_audio.Operation, deadline: u64) !u64 {
        if (!self.cursorWorkAvailable() or self.channel.?.phase != .idle) return error.Busy;
        if (deadline <= try self.now() or self.audio_sequence == std.math.maxInt(u64)) return error.Deadline;
        const expected = try display_audio.derive(plan.mode, self.display_object.?, self.outputs.snapshot() orelse return error.Stale);
        if (!std.meta.eql(plan, expected)) return error.Stale;
        return self.startDisplayAudio(plan, operation, deadline, false);
    }
    /// Disable only the previously acknowledged video route. Fresh receiver
    /// data cannot authorize enabling an old ELD, and is not needed to clear it.
    pub fn beginDisplayDisconnect(self: *Owner, window: u32, operation: display_audio.Operation, deadline: u64) !u64 {
        if (!self.outputPaused(window) or window >= 8 or (operation != .mute and operation != .clear and operation != .disable)) return error.State;
        if (!self.cursorWorkAvailable() or self.channel.?.phase != .idle) return error.Busy;
        if (deadline <= try self.now() or self.audio_sequence == std.math.maxInt(u64)) return error.Deadline;
        const active = self.display_images[window] orelse return error.State;
        const mode = active.boot_mode orelse return error.State;
        const link = active.link orelse return error.State;
        if (active.core_point == 0 or active.window_point == 0 or !link.complete() or !mode.hasAudio()) return error.State;
        return self.startDisplayAudio(.{ .object = link.plan.object, .mode = mode }, operation, deadline, true);
    }
    fn startDisplayAudio(self: *Owner, plan: display_audio.Plan, operation: display_audio.Operation, deadline: u64, retiring: bool) !u64 {
        var encoded: [display_audio.max_bytes]u8 = undefined;
        _ = try display_audio.encode(plan, operation, &encoded);
        self.audio_sequence += 1;
        self.audio_work = .{ .plan = plan, .operation = operation, .sequence = self.audio_sequence, .deadline = deadline, .retiring = retiring };
        errdefer self.audio_work = null;
        try self.validateDisplayAudio();
        return self.audio_sequence;
    }
    pub fn validateDisplayAudio(self: *Owner) !void {
        const work = self.audio_work orelse return error.State;
        if (self.failure != null or self.graph_closing or self.display_object == null or !std.meta.eql(work.plan.object, self.display_object.?) or
            work.plan.object.epoch != self.epoch or self.activeChannel() != &self.channel.? or self.display_work != null or
            self.hasDisplayFlips() or self.cursor_point != null) return error.Stale;
        if (work.retiring) {
            if (!self.outputPaused(work.plan.mode.window) or (work.operation != .mute and work.operation != .clear and work.operation != .disable) or work.plan.data != null or
                work.plan.mode.window >= 8) return error.Stale;
            const active = self.display_images[work.plan.mode.window] orelse return error.Stale;
            if (active.boot_mode == null or !std.meta.eql(active.boot_mode.?, work.plan.mode) or active.link == null or
                !std.meta.eql(active.link.?.plan.object, work.plan.object) or active.core_point == 0 or active.window_point == 0 or
                active.link.?.receipt == 0) return error.Stale;
        }
        // Invalidate/mute is also valid before the initial scanout. Enabling
        // requires an actually completed video mode, including its HDMI ACKs.
        if (work.operation == .publish or work.operation == .unmute or work.operation == .enable) {
            const engine = if (self.display_engine_owner) |*value| value else return error.State;
            const image = try self.displayImageStatus(.{ .epoch = self.epoch, .root = engine.binding.root }, work.plan.mode.window) orelse return error.State;
            if (image.boot_mode == null or !std.meta.eql(image.boot_mode.?, work.plan.mode) or image.core_point == 0 or
                image.window_point == 0 or image.link == null or !image.link.?.complete()) return error.Stale;
            if (work.plan.mode.displayPort() and !image.link.?.audio48k()) return error.Unsupported;
        }
    }
    fn advanceDisplayAudio(self: *Owner, current: u64) !Progress {
        const work = &self.audio_work.?;
        const channel = &self.channel.?;
        try self.validateDisplayAudio();
        if (current >= work.deadline) return error.Timeout;
        if (!work.pending) {
            work.length = try display_audio.encode(work.plan, work.operation, &work.request);
            try channel.begin(display_audio.function, work.request[0..work.length], work.deadline);
            work.pending = true;
            return .progress;
        }
        if (try channel.poll(work.deadline)) |dispatch| {
            if (!dispatch.response) { try self.notification(channel, dispatch, current); return .progress; }
            const reply = try display_audio.decode(work.plan, work.operation, dispatch.record);
            try channel.complete(dispatch.ticket);
            self.audio_result = .{ .sequence = work.sequence, .operation = work.operation, .receipt = dispatch.ticket.serial,
                .status = reply.status, .rpc_error = reply.rpc_error };
            if (reply.status != 0) self.log("NVIDIA HDMI audio: operation={s} status={x} rpc={} video=preserved",
                .{@tagName(work.operation), reply.status, reply.rpc_error});
            self.audio_work = null;
            return .progress;
        }
        return if (channel.phase == .waiting) .idle else .progress;
    }
    /// Window flips do not own CE. Recheck every protected image at the real
    /// submission gate; another head's shadow is deliberately independent.
    pub fn validateCopyOverlap(self: *Owner) !void {
        if (!self.hasDisplayFlips()) return;
        if (!self.overlapFlip()) return error.Stale;
        for (&self.display_flips, 0..) |*slot, window| if (slot.*) |*flip_work| {
            try self.validateOutputFlip(@intCast(window));
            if (self.copy_job) |work| {
                if (work.target_presentation) |target| {
                    if (target == flip_work.presentation or target.surface.scanout.?.dma == flip_work.previous.image.dma) return error.Stale;
                    if (target.window.slot == flip_work.presentation.window.slot and
                        !std.meta.eql(target.surface.shadow.buffer, flip_work.presentation.surface.shadow.buffer)) return error.Stale;
                } else if (work.presentation) return error.Stale
                else try self.validateOffscreenTarget(work.job.target_buffer);
            } else if (self.graphics_upload == null) return error.State;
        };
    }
    fn validateOffscreenTarget(self: *Owner, buffer: r4os.abi.GfxBufferHandle) !void {
        // Queue writers never inherit the display owner's private VRAM use.
        // This also covers aliases of ready or retained presentation images.
        for (&self.presentation_slots) |*slot| if (slot.*) |*entry| {
            const storage = entry.surface.target orelse return error.Stale;
            const source = storage.info() orelse return error.Stale;
            if (std.meta.eql(source.reference.buffer, buffer)) return error.Stale;
        };
    }
    pub fn presentationGroupCount(self: *Owner, entry: *Presentation) usize {
        var count: usize = 0;
        for (&self.presentation_slots) |*slot| if (slot.*) |*peer| {
            if (!peer.retiring and peer.direct == null and std.meta.eql(peer.window, entry.window) and
                std.meta.eql(peer.surface.shadow.buffer, entry.surface.shadow.buffer)) count += 1;
        };
        return count;
    }
    pub fn presentationPeer(self: *Owner, buffer: r4os.abi.GfxBufferHandle) ?u32 {
        for (&self.presentation_slots) |*slot| if (slot.*) |*peer| {
            if (!peer.retiring and peer.direct == null and std.meta.eql(peer.surface.shadow.buffer, buffer)) return peer.surface.scanout.?.dma;
        };
        return null;
    }
    pub fn presentationImageBuffer(self: *Owner, dma: u32) !r4os.abi.GfxBufferHandle {
        return (try self.findPresentationImage(dma)).surface.shadow.buffer;
    }
    fn acquireFrame(self: *Owner, current: *Presentation) !?*Presentation {
        const resources = self.display_resources_slot.owner orelse return error.State;
        const start = (self.presentationIndex(current) orelse return error.Stale) + 1;
        // Rotate through the bounded group, including its third buffer.
        // FINISHED is required even when an earlier frame used this image.
        for (0..self.presentation_slots.len) |offset| {
            const slot = &self.presentation_slots[(start + offset) % self.presentation_slots.len];
            const entry = if (slot.*) |*value| value else continue;
            if (entry == current or entry.direct != null or !self.preparedPresentation(entry) or
                !std.meta.eql(entry.window, current.window) or
                !std.meta.eql(entry.surface.shadow.buffer, current.surface.shadow.buffer)) continue;
            if (self.readyImage(entry.window.slot - 1)) |ready| if (ready.image == entry) continue;
            if (self.presentationHeld(entry)) continue;
            if (self.displayFlip(entry.window.slot - 1)) |work| if (entry == work.presentation or entry.surface.scanout.?.dma == work.previous.image.dma) continue;
            if (try resources.imageFinished(entry.window.slot, entry.surface.scanout.?.dma)) return entry;
        }
        return null;
    }
    fn presentationHeld(self: *const Owner, entry: *const Presentation) bool {
        for (&self.work_slots) |*slot| switch (slot.*) {
            .copy => |*work| if (work.target_presentation == entry) return true,
            else => {},
        };
        return false;
    }
    pub fn prepareFramePool(self: *Owner) !bool {
        const current = if (self.frame_setup) |work| work.image else self.presentation orelse return false;
        return self.prepareOutputFramePool(current.window.slot - 1);
    }
    pub fn prepareOutputFramePool(self: *Owner, window: u32) !bool {
        return self.prepareOutputFramePoolImpl(window, false, std.math.maxInt(u64));
    }
    /// A trial mode needs live presentation before KEEP, which can then
    /// outlive its SYSTEM producer. Admit every private spare's independent
    /// shadow import before either receipt, without waiting for a first frame.
    pub fn prepareConfirmedModeFrames(self: *Owner, window: u32, deadline: u64) !bool {
        return self.prepareOutputFramePoolImpl(window, true, deadline);
    }
    fn prepareOutputFramePoolImpl(self: *Owner, window: u32, required: bool, deadline: u64) !bool {
        const current = self.currentPresentation(window) orelse return false;
        if (self.frame_setup) |work| if (work.image.window.slot != window + 1) return false;
        if (self.outputPaused(window) and self.frame_setup == null) return false;
        if (self.frame_setup == null and (self.presentation_buffers == 0 or (!required and !current.pending))) return false;
        if (self.frame_setup == null) {
            if (self.presentationGroupCount(current) >= self.presentation_buffers) {
                // Publish direct capability only once the private fallback
                // pool exists. GR may have been admitted before this output;
                // preserve its exact accepted catalog when adding scanout.
                if (current == self.presentation and self.preparing_outputs == 0 and !self.hasOtherOutput(window) and
                    !self.direct_enabled and self.presentation_buffers >= 2) {
                    const backend = self.copy_backend orelse return false;
                    if (backend.queue.supportsScanout()) {
                        // Direct retirement also needs the ordinary image-to-output
                        // fallback. Keep every accepted render bit while adding both.
                        const operations = backend.operations | 32 | 128;
                        const rc = backend.queue.updateOperations(&backend.binding, operations);
                        if (rc == r4os.abi.gfx_queue_error_busy) return error.Busy;
                        if (rc == r4os.abi.gfx_queue_ok) { self.copy_backend.?.operations = operations; self.direct_enabled = true; return true; }
                        if (rc != r4os.abi.err_no_fn and rc != r4os.abi.gfx_queue_error_invalid) return error.Queue;
                    }
                }
                return false;
            }
            if (self.copyBusy() or !self.validPresentation(current) or self.nativeObject() == null) return false;
            self.frame_setup = .{ .image = current, .deadline = @min((try self.now()) +| 3 * std.time.ns_per_s, deadline) };
        }
        const work = &self.frame_setup.?;
        if (work.image != current or !self.preparedPresentation(current)) return error.Stale;
        const phase = work.phase;
        if (try work.step(self)) { self.frame_setup = null; return true; }
        return work.phase != phase;
    }
    /// Called after the product owner populated and unmapped its CPU shadow
    /// from the same immutable capture used by common commit. This private
    /// operation does not invent a common queue fence.
    pub fn uploadInitialImage(self: *Owner, deadline: u64) !void {
        if (!self.presentationPrepared()) return error.State;
        const entry = self.presentation.?;
        if (self.display_images[entry.window.slot - 1] != null) return error.Busy;
        return self.uploadDisplayPresentationImage(entry.surface.scanout.?.dma, deadline);
    }
    pub fn uploadDisplayPresentationImage(self: *Owner, dma: u32, deadline: u64) !void {
        const entry = try self.findPresentationImage(dma);
        if (!self.preparedPresentation(entry)) return error.State;
        const fifo = try self.findChannel(entry.channel_handle);
        if (entry.initial_point != 0 or self.copyBusy() or
            self.graph_closing or !fifo.ring.idle() or self.fifo_active != null or self.context_active != null or
            self.virtuals.active_range != null or self.native_active != null or self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or
            self.display_engine_active or self.display_channel_active != null or self.channel.?.phase != .idle or self.channel.?.in_lockdown)
            return error.Busy;
        if (self.display_images[entry.window.slot - 1]) |active| if (active.image.dma == dma) return error.Busy;
        try self.channel.?.guard(deadline);
        entry.initial_failure = null;
        self.initial_image = .{ .presentation = entry, .deadline = deadline };
    }
    pub fn refreshDetachedImage(self: *Owner, dma: u32, deadline: u64) !void {
        const entry = try self.findPresentationImage(dma);
        const window = entry.window.slot - 1;
        const retired = self.display_retired[window] orelse return error.State;
        if (!self.outputPaused(window) or retired.epoch != self.epoch or retired.core_point == 0 or retired.window_point == 0 or
            self.display_images[window] != null or !self.preparedPresentation(entry)) return error.Stale;
        if (self.copyBusy() or self.nativeObject() == null) return error.Busy;
        if (!try self.display_resources_slot.owner.?.imageFinished(entry.window.slot, dma)) return error.Busy;
        // Headless CPU drawing may have changed every byte. Refresh from a
        // new common read lease; no cached frame or old CE fence is reused.
        // The other images in this pool also lost their incremental baseline.
        for (&self.presentation_slots) |*slot| if (slot.*) |*image| {
            if (std.meta.eql(image.window, entry.window) and std.meta.eql(image.surface.shadow.buffer, entry.surface.shadow.buffer))
                image.damage = .{ .x = 0, .y = 0, .width = entry.surface.descriptor.width, .height = entry.surface.descriptor.height };
        };
        entry.initial_point = 0; entry.render_fence = .{}; entry.damage = null;
        try self.uploadDisplayPresentationImage(dma, deadline);
    }
    pub fn initialImageStatus(self: *Owner) !InitialImageStatus {
        if (!self.presentationPrepared()) return error.State;
        return self.presentationImageStatus(self.presentation.?.surface.scanout.?.dma);
    }
    pub fn presentationImageStatus(self: *Owner, dma: u32) !InitialImageStatus {
        const entry = try self.findPresentationImage(dma);
        if (!self.preparedPresentation(entry)) return error.State;
        return .{ .pending = if (self.initial_image) |work| work.presentation == entry else false,
            .completed = entry.initial_point, .failure = entry.initial_failure };
    }
    /// Discover the engine and create its RM group/share in this VA space.
    /// Channel children retain the context separately before using it.
    pub fn createExecutionContext(self: *Owner, rm_engine: u32, deadline: u64) !ContextHandle {
        return self.createContext(rm_engine, deadline) catch |err| { self.hostRejection(.context, err); return err; };
    }
    fn createContext(self: *Owner, rm_engine: u32, deadline: u64) !ContextHandle {
        try self.admitNativeRmCreation();
        const internal_query = rm_engine == 1 or (rm_engine >= 9 and rm_engine <= 28) or execution_context.wire.videoEngine(rm_engine);
        if (internal_query and self.static_info == null) return error.State;
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        const subdevice = self.graph.?.base.plan.handles.subdevice;
        _ = try execution_context.wire.nvEngine(rm_engine);
        try self.channel.?.guard(deadline);
        const serial = try std.math.add(u64, self.buffer_serial, 1);
        const index: u16 = blk: {
            for (&self.contexts, 0..) |*slot, i| if (slot.allocation.handle == 0) break :blk @intCast(i);
            return error.Exhausted;
        };
        const heap = self.ctx.?.heap() orelse return error.Api;
        const slot = &self.contexts[index]; slot.heap = heap;
        const result = heap.allocate(@sizeOf(execution_context.Owner), @alignOf(execution_context.Owner), &slot.allocation);
        const allocation = slot.allocation;
        if (result != r4os.abi.driver_heap_ok and allocation.handle == 0) return error.Memory;
        if (allocation.version != 1 or allocation.size < @sizeOf(r4os.abi.DriverHeapAllocation) or allocation.handle == 0 or
            allocation.cpu_address == 0 or allocation.cpu_address % @alignOf(execution_context.Owner) != 0 or allocation.reserved != 0 or
            allocation.byte_length < @sizeOf(execution_context.Owner) or allocation.alignment < @alignOf(execution_context.Owner) or
            allocation.cpu_address > std.math.maxInt(u64) - allocation.byte_length) {
            self.stop(error.Descriptor); return error.Descriptor;
        }
        errdefer if (heap.release(allocation.handle) == r4os.abi.driver_heap_ok) { slot.* = .{}; } else self.stop(error.Retained);
        if (result != r4os.abi.driver_heap_ok) return error.Memory;
        var token = try self.channel.?.handoff(deadline);
        const owner: *execution_context.Owner = @ptrFromInt(allocation.cpu_address);
        owner.initInto(&token, self.graph.?.reservation, space, subdevice, rm_engine, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        if (internal_query) {
            owner.binding.internal_client = self.static_info.?.client;
            owner.binding.internal_subdevice = self.static_info.?.subdevice;
        }
        slot.owner = owner; slot.serial = serial; self.buffer_serial = serial; self.context_active = index;
        return .{ .epoch = self.epoch, .serial = serial, .slot = index };
    }
    fn findContext(self: *Owner, handle: ContextHandle) !*execution_context.Owner {
        _ = try self.now();
        if (handle.epoch != self.epoch or handle.slot >= self.contexts.len or handle.serial == 0 or self.contexts[handle.slot].serial != handle.serial) return error.Stale;
        return self.contexts[handle.slot].owner orelse return error.Stale;
    }
    pub fn executionContextStatus(self: *Owner, handle: ContextHandle) !ContextStatus {
        const owner = try self.findContext(handle);
        return .{ .state = owner.state, .info = owner.info(), .rejected = owner.rejected, .unavailable = owner.unavailable };
    }
    pub fn retainExecutionContext(self: *Owner, handle: ContextHandle) !execution_context.Child {
        if (self.graph_closing) return error.Busy;
        return (try self.findContext(handle)).retainChild();
    }
    pub fn releaseExecutionContextChild(self: *Owner, handle: ContextHandle, child: execution_context.Child, quiesced: bool) !void {
        try (try self.findContext(handle)).releaseChild(child, quiesced);
    }
    pub fn attachContextMethods(self: *Owner, context: ContextHandle, runqueue: u8, buffer: BufferHandle) !void {
        if (self.copyBusy() or self.graph_closing or self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.display_engine_active or self.display_channel_active != null) return error.Busy;
        const owner = try self.findContext(context);
        try owner.attachMethods(runqueue, try self.findNativeBuffer(buffer));
    }
    pub fn attachFalconContextBuffer(self: *Owner, context: ContextHandle, buffer: BufferHandle) !void {
        if (self.copyBusy() or self.graph_closing or self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or
            self.native_active != null or self.display_engine_active or self.display_channel_active != null) return error.Busy;
        try (try self.findContext(context)).attachFalcon(try self.findNativeBuffer(buffer));
    }
    pub fn createRegularGraphicsContext(self: *Owner, golden: ContextHandle, deadline: u64) !ContextHandle {
        const source = try self.findContext(golden);
        if (!source.golden_complete or source.graphics_plan == null) return error.State;
        const handle = try self.createExecutionContext(1, deadline);
        const owner = try self.findContext(handle);
        owner.graphics_golden = false; owner.graphics_plan = source.graphics_plan;
        return handle;
    }
    pub fn graphicsContextRequirement(self: *Owner, context: ContextHandle, index: usize) !?execution_context.wire.graphics.Requirement {
        return (try self.findContext(context)).graphicsRequirement(index);
    }
    pub fn attachGraphicsContextBuffer(self: *Owner, context: ContextHandle, index: usize, buffer: BufferHandle) !void {
        if (self.executionAdmissionBusy() or self.queued_render != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.fifo_active != null or self.graph_closing) return error.Busy;
        try (try self.findContext(context)).attachGraphics(index, try self.findNativeBuffer(buffer));
    }
    pub fn shareGraphicsContextGlobals(self: *Owner, context: ContextHandle, golden: ContextHandle) !void {
        if (self.executionAdmissionBusy() or self.queued_render != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.fifo_active != null or self.graph_closing) return error.Busy;
        try (try self.findContext(context)).shareGraphicsGlobals(try self.findContext(golden));
    }
    pub fn retireExecutionContext(self: *Owner, handle: ContextHandle, deadline: u64) !void {
        const owner = try self.findContext(handle);
        if (self.copyBusy() or self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        if (owner.held()) return error.Retained;
        var token = try self.channel.?.handoff(deadline);
        owner.beginDestroy(&token, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        self.context_active = handle.slot;
    }
    fn freeContextSlot(self: *Owner, index: usize) !void {
        const slot = &self.contexts[index];
        const heap = slot.heap orelse return error.Api;
        if (heap.release(slot.allocation.handle) != r4os.abi.driver_heap_ok) return error.Retained;
        slot.* = .{};
    }
    /// Attach an empty private GPFIFO to an existing context and native BOs.
    /// Only this driver API accepts storage owners; no physical app address.
    pub fn createExecutionChannel(self: *Owner, context_handle: ContextHandle, runqueue: u8, instance: BufferHandle, userd: BufferHandle, deadline: u64) !ChannelHandle {
        return self.createChannel(context_handle, runqueue, instance, userd, .none, deadline);
    }
    /// Explicit native worker path; creating it does not publish renderer or
    /// display capabilities. The CE class is queried and allocated by RM.
    pub fn createCopyChannel(self: *Owner, context_handle: ContextHandle, runqueue: u8, instance: BufferHandle, deadline: u64) !ChannelHandle {
        return self.createChannel(context_handle, runqueue, instance, null, .copy, deadline);
    }
    /// Decoder object under an actually enumerated NVDEC context. This does
    /// not advertise codecs; picture/status and output admission are separate.
    pub fn createNvdecChannel(self: *Owner, context_handle: ContextHandle, runqueue: u8, instance: BufferHandle, deadline: u64) !ChannelHandle {
        return self.createChannel(context_handle, runqueue, instance, null, .nvdec, deadline);
    }
    /// NVENC owns a separate engine context; allocation is not a successful
    /// encoding receipt. The producer must inspect per-picture status/length.
    pub fn createNvencChannel(self: *Owner, context_handle: ContextHandle, runqueue: u8, instance: BufferHandle, deadline: u64) !ChannelHandle {
        return self.createChannel(context_handle, runqueue, instance, null, .nvenc, deadline);
    }
    /// Pinned C797 graphics channel, separate from CE but using the same RM
    /// ownership, private USERD and protected submission transport.
    pub fn createGraphicsChannel(self: *Owner, context_handle: ContextHandle, runqueue: u8, instance: BufferHandle, deadline: u64) !ChannelHandle {
        return self.createChannel(context_handle, runqueue, instance, null, .graphics, deadline);
    }
    fn createChannel(self: *Owner, context_handle: ContextHandle, runqueue: u8, instance: BufferHandle, userd: ?BufferHandle, engine: execution_fifo.wire.Engine, deadline: u64) !ChannelHandle {
        return self.openChannel(context_handle, runqueue, instance, userd, engine, execution_fifo.wire.defaultEngineMask(engine), deadline) catch |err| { self.hostRejection(.channel, err); return err; };
    }
    pub fn createNativeGraphicsChannel(self: *Owner, context_handle: ContextHandle, runqueue: u8, instance: BufferHandle, engine_mask: u32, deadline: u64) !ChannelHandle {
        return self.openChannel(context_handle, runqueue, instance, null, .graphics, engine_mask, deadline) catch |err| { self.hostRejection(.channel, err); return err; };
    }
    fn openChannel(self: *Owner, context_handle: ContextHandle, runqueue: u8, instance: BufferHandle, userd: ?BufferHandle, engine: execution_fifo.wire.Engine, engine_mask: u32, deadline: u64) !ChannelHandle {
        try self.admitNativeRmCreation();
        _ = self.nativeAddressSpace() orelse return error.State;
        const parent = try self.findContext(context_handle);
        const inst = try self.findNativeBuffer(instance); const usr = if (userd) |handle| try self.findNativeBuffer(handle) else null;
        try self.channel.?.guard(deadline);
        const serial = try std.math.add(u64, self.buffer_serial, 1);
        const index: u16 = blk: {
            for (&self.fifos, 0..) |*slot, i| if (slot.allocation.handle == 0) break :blk @intCast(i);
            return error.Exhausted;
        };
        const heap = self.ctx.?.heap() orelse return error.Api;
        const slot = &self.fifos[index]; slot.heap = heap;
        const result = heap.allocate(@sizeOf(execution_fifo.Owner), @alignOf(execution_fifo.Owner), &slot.allocation);
        const allocation = slot.allocation;
        if (result != r4os.abi.driver_heap_ok and allocation.handle == 0) return error.Memory;
        if (allocation.version != 1 or allocation.size < @sizeOf(r4os.abi.DriverHeapAllocation) or allocation.handle == 0 or
            allocation.cpu_address == 0 or allocation.cpu_address % @alignOf(execution_fifo.Owner) != 0 or allocation.reserved != 0 or
            allocation.byte_length < @sizeOf(execution_fifo.Owner) or allocation.alignment < @alignOf(execution_fifo.Owner) or
            allocation.cpu_address > std.math.maxInt(u64) - allocation.byte_length) {
            self.stop(error.Descriptor); return error.Descriptor;
        }
        var retained = false;
        errdefer if (!retained) {
            if (heap.release(allocation.handle) == r4os.abi.driver_heap_ok) slot.* = .{} else self.stop(error.Retained);
        };
        if (result != r4os.abi.driver_heap_ok) return error.Memory;
        const owner: *execution_fifo.Owner = @ptrFromInt(allocation.cpu_address); owner.* = .{};
        var token = try self.channel.?.handoff(deadline);
        owner.openEngines(&token, &self.ctx.?, self.adapter_id, self.graph.?.reservation, parent, runqueue,
            try execution_fifo.wire.hardwareChannelForSlot(index), inst, usr, engine, engine_mask, deadline) catch |err| {
            if (owner.failure != null) {
                retained = true; slot.owner = owner; slot.serial = serial; self.buffer_serial = serial;
                self.stop(err); return err;
            }
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        slot.owner = owner; slot.serial = serial; self.buffer_serial = serial; self.fifo_active = index;
        return .{ .epoch = self.epoch, .serial = serial, .slot = index };
    }
    fn findChannel(self: *Owner, handle: ChannelHandle) !*execution_fifo.Owner {
        _ = try self.now();
        if (handle.epoch != self.epoch or handle.slot >= self.fifos.len or handle.serial == 0 or self.fifos[handle.slot].serial != handle.serial) return error.Stale;
        return self.fifos[handle.slot].owner orelse return error.Stale;
    }
    pub fn executionChannelStatus(self: *Owner, handle: ChannelHandle) !ChannelStatus {
        const owner = try self.findChannel(handle);
        return .{ .state = owner.state, .info = owner.info(), .rejected = owner.rejected, .host_rejected = owner.host_rejected };
    }
    pub fn graphicsClass(self: *const Owner) !u32 {
        const device = self.device orelse return error.State;
        const session = device.runtime_session orelse return error.State;
        if (session.epoch != self.epoch) return error.Stale;
        return (@import("generation.zig").get(session.profile.chip_id) orelse return error.Unsupported).render;
    }
    pub fn nvdecClass(self: *const Owner) !u32 {
        const device = self.device orelse return error.State;
        const session = device.runtime_session orelse return error.State;
        if (session.epoch != self.epoch) return error.Stale;
        return (@import("generation.zig").get(session.profile.chip_id) orelse return error.Unsupported).nvdecClass();
    }
    pub fn nvencClass(self: *const Owner) !u32 {
        const device = self.device orelse return error.State;
        const session = device.runtime_session orelse return error.State;
        if (session.epoch != self.epoch) return error.Stale;
        return (@import("generation.zig").get(session.profile.chip_id) orelse return error.Unsupported).nvencClass();
    }
    pub fn attachGraphicsCache(self: *Owner, kind: render_cache.Kind, buffer: BufferHandle) !void {
        _ = try self.now();
        if (self.copyBusy() or self.graph_closing) return error.Busy;
        if (self.graphics_cache.self_address == 0) try self.graphics_cache.initializeFor(self.epoch, try self.graphicsClass());
        if (!self.graphics_cache.valid() or self.graphics_cache.epoch != self.epoch or self.graphics_cache.borrowed or self.graphics_cache.uploading != null) return error.Stale;
        const storage = self.graphics_cache.buffer(kind);
        if (storage.self_address != 0) return error.Busy;
        const info = (try self.findNativeBuffer(buffer)).info() orelse return error.State;
        if (info.surface.request != null or info.surface.privileged or info.surface.readonly) return error.Unsupported;
        try self.graphics_cache.admitStorage(kind,info.allocation_bytes);
        try (render.Range{ .address = info.address, .bytes = info.logical_bytes }).validate(256, if (kind == .programs) try render.shaderBytesFor(self.graphics_cache.class) else render.packet_bytes);
        try self.retainNativeStorage(buffer,storage);
    }
    pub fn beginGraphicsUpload(self: *Owner, handle: ChannelHandle, kind: render_cache.Kind, draw: ?render.Draw, deadline: u64) !void {
        return self.startGraphicsUpload(handle, kind, if (draw) |value| &.{value} else &.{}, deadline, false);
    }
    fn startGraphicsUpload(self: *Owner, handle: ChannelHandle, kind: render_cache.Kind, draws: []const render.Draw, deadline: u64, queued: bool) !void {
        const current = try self.now();
        if (deadline == std.math.maxInt(u64)) return error.Deadline;
        if (deadline <= current) return if (queued) error.AdmissionExpired else error.Deadline;
        if (self.commandExchangeBusy() or self.executionWorkBusy() or (self.hasDisplayFlips() and !self.overlapFlip()) or
            (!queued and self.queued_render != null) or self.cursor_reserving or self.graph_closing) return error.Busy;
        const fifo = try self.findChannel(handle);
        const info = fifo.info() orelse return error.State;
        if (info.config.engine != .copy or !fifo.ring.idle() or !info.config.system_userd) return error.Unsupported;
        const staging = if (self.graph.?.control_buffer) |*value| value else return error.State;
        if (staging.binding.space.handle != info.config.context.vaspace or self.graphics_cache.epoch != self.epoch) return error.Stale;
        if (queued) try self.channel.?.guardUnsubmitted(deadline) else try self.channel.?.guard(deadline);
        self.graphics_upload = .{ .channel = handle, .queued = queued };
        self.graphics_upload.?.operation.openList(&self.graphics_cache,staging,kind,draws,deadline) catch |err| {
            if (self.graphics_upload.?.operation.failed) self.stop(err) else self.graphics_upload = null;
            return err;
        };
    }
    fn graphicsResource(self: *Owner, handle: BufferHandle) !render_job.Resource {
        const owner = try self.findNativeBuffer(handle);
        return .{ .info = owner.info() orelse return error.State, .driver_owner = owner.reservation.driver_owner };
    }
    pub fn graphicsImage(self: *Owner, handle: BufferHandle, target: bool) !render.image.Image {
        return render_job.image(try self.graphicsResource(handle),target);
    }
    pub fn enableGraphicsQueue(self: *Owner, handle: ChannelHandle, copy_handle: ChannelHandle) !void {
        if (self.copyBusy() or self.graph_closing or self.graphics_enabled) return error.Busy;
        const fifo = try self.findChannel(handle);
        const info = fifo.info() orelse return error.State;
        if (info.config.engine != .graphics or info.config.graphics == null or info.config.graphics.?.golden or
            !self.graphics_cache.valid() or self.graphics_cache.program_point == 0 or self.graphics_cache.packet.info() == null) return error.State;
        if (info.config.object_class != try self.graphicsClass() or self.graphics_cache.class != info.config.object_class) return error.Binding;
        const copy = (try self.findChannel(copy_handle)).info() orelse return error.State;
        if (copy.config.engine != .copy or copy.config.context.vaspace != info.config.context.vaspace) return error.Binding;
        const backend = self.copy_backend orelse return error.State;
        const lists = backend.queue.supportsRenderList() and self.graphics_cache.packet.info().?.bytes >= render.packet_capacity_bytes;
        const direct = backend.queue.supportsScanout() and self.presentation != null and self.presentation_buffers >= 2;
        const display_bits: u64 = if (self.presentation != null) 36 else 0; // upload and image-to-output
        const native_bit = backend.operations & native_queue.operation_bit;
        const ordinary: u64 = (if (lists) @as(u64, 89) else 25) | display_bits | native_bit;
        const grid: u64 = if (lists and backend.queue.supportsRenderGridList()) 256 else 0;
        const color: u64 = if (lists and backend.queue.supportsRenderColorList()) 512 else 0;
        var operations = ordinary | @as(u64, if (direct) 128 else 0) | grid | color;
        const combined: u64 = if (grid != 0 and color != 0) @as(u64, 1) << r4os.abi.gfx_queue_operation_render_color_grid_list else 0;
        operations |= combined;
        var rc = backend.queue.updateOperations(&backend.binding, operations);
        // Old kernels can retain their separate color/grid operations. Never
        // advertise fused sampling just because both older bits are present.
        if (combined != 0 and rc == r4os.abi.gfx_queue_error_invalid) {
            operations &= ~combined;
            rc = backend.queue.updateOperations(&backend.binding, operations);
        }
        self.direct_enabled = direct and rc == r4os.abi.gfx_queue_ok;
        if ((direct or grid != 0 or color != 0) and rc == r4os.abi.gfx_queue_error_invalid) { operations = ordinary; rc = backend.queue.updateOperations(&backend.binding, operations); }
        if (rc == r4os.abi.gfx_queue_error_invalid and lists) { operations = 25 | display_bits | native_bit; rc = backend.queue.updateOperations(&backend.binding, operations); }
        // Earlier common queues can still use offscreen rendering. They
        // never receive the new image-to-output operation.
        if (rc == r4os.abi.gfx_queue_error_invalid) { operations = 25 | (display_bits & 4) | native_bit; rc = backend.queue.updateOperations(&backend.binding, operations); }
        if (rc == r4os.abi.err_no_fn) return error.Unsupported;
        if (rc != r4os.abi.gfx_queue_ok) return error.Queue;
        self.copy_backend.?.operations = operations;
        self.graphics_channel = handle; self.graphics_copy_channel = copy_handle; self.graphics_enabled = true;
    }
    fn queuedRender(self: *Owner, input: *render_queue.Owner) !void {
        const held = if (self.queued_render) |value| value else return error.State;
        if (input != held or !held.valid() or !self.graphics_enabled or self.graphics_channel == null or
            self.copy_backend == null or !std.meta.eql(held.binding, self.copy_backend.?.binding)) return error.Stale;
    }
    fn queuedGraphicsResource(self: *Owner, reference: r4os.abi.GfxBufferReference) !render_job.Resource {
        const space = self.nativeAddressSpace() orelse return error.State;
        return self.queuedGraphicsResourceInSpace(reference, space.handle);
    }
    // Read an already retained mapping in the exact command channel's VA
    // space. This neither admits a new use nor exposes nativeAddressSpace
    // while a cursor/display owner temporarily hides fresh device access.
    fn queuedGraphicsResourceInSpace(self: *Owner, reference: r4os.abi.GfxBufferReference, space: u32) !render_job.Resource {
        for (self.native_buffers.items()) |*slot| if (slot.owner) |owner| if (owner.queuedInfo(reference)) |value| {
            if (value.epoch != self.epoch or owner.binding.space.handle != space) return error.Stale;
            return .{ .info = value, .driver_owner = owner.reservation.driver_owner };
        };
        return error.Unsupported;
    }
    // A retained public job may be between physical slices when the cursor
    // or another display/RM owner is admitted. Its native address space is
    // intentionally hidden until that exact work hands back the device.
    // Wait before looking up operands or reusing/reserving a cache packet.
    fn queuedGraphicsAdmission(self: *Owner, input: *render_queue.Owner) !void {
        try self.queuedRender(input);
        if (self.commandExchangeBusy() or self.executionAdmissionBusy() or
            self.cursor_point != null or self.graph_closing) return error.Busy;
    }
    pub fn prepareQueuedGraphics(self: *Owner, input: *render_queue.Owner) !void {
        try self.queuedGraphicsAdmission(input);
        if (input.phase != .prepare or input.draw_count != 0) return error.Binding;
        try self.validateOffscreenTarget(input.job.target_buffer);
        for (input.list.commands[0..input.list.count], 0..) |command, i| {
            const draw = self.queuedGraphicsDraw(input, command, input.grids[i]) catch |err| { if (err == error.Empty) continue; return err; };
            if (input.draw_count != 0 and !render.compatible(input.draws[0], draw)) return error.Binding;
            input.draws[input.draw_count] = draw; input.draw_count += 1;
        }
        if (input.draw_count == 0) return error.Empty;
    }
    fn validateQueuedGraphics(self: *Owner, input: *render_queue.Owner) !void {
        const space = self.nativeAddressSpace() orelse return error.State;
        return self.validateQueuedGraphicsInSpace(input, space.handle);
    }
    fn validateQueuedGraphicsInSpace(self: *Owner, input: *render_queue.Owner, space: u32) !void {
        try self.queuedRender(input);
        try self.validateOffscreenTarget(input.job.target_buffer);
        var count: usize = 0;
        for (input.list.commands[0..input.list.count], 0..) |command, i| {
            const draw = self.queuedGraphicsDrawInSpace(input, command, input.grids[i], space) catch |err| { if (err == error.Empty) continue; return err; };
            if (count >= input.draw_count or !std.meta.eql(draw, input.draws[count])) return error.Binding;
            count += 1;
        }
        if (count == 0 or count != input.draw_count) return error.Binding;
        try input.validateSlice();
    }
    fn queuedGraphicsDraw(self: *Owner, input: *render_queue.Owner, state: r4os.abi.GfxRenderCommand, grid: r4os.abi.GfxSampleGrid) !render.Draw {
        const space = self.nativeAddressSpace() orelse return error.State;
        return self.queuedGraphicsDrawInSpace(input, state, grid, space.handle);
    }
    fn queuedGraphicsDrawInSpace(self: *Owner, input: *render_queue.Owner, state: r4os.abi.GfxRenderCommand,
        grid: r4os.abi.GfxSampleGrid, space: u32) !render.Draw {
        try self.queuedRender(input);
        if (state.kind > r4os.abi.gfx_render_kind_sample or state.filter > 1 or state.blend > 1 or state.transfer > 3 or state.opacity > 255) return error.Bounds;
        const sampled = state.kind == r4os.abi.gfx_render_kind_sample;
        if (!sampled and (input.job.source_buffer.id != 0 or input.job.source_buffer.generation != 0 or
            !std.meta.eql(state.source_rect, r4os.abi.GfxRenderRect{}) or state.filter != 0)) return error.Bounds;
        const result: render.Draw = .{ .target = try render_job.queuedImage(try self.queuedGraphicsResourceInSpace(input.references[1], space), true),
            .source = if (sampled) try render_job.queuedImage(try self.queuedGraphicsResourceInSpace(input.references[0], space), false) else null,
            .destination = renderRect(state.target_rect), .source_rect = if (sampled) renderRect(state.source_rect) else .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .scissor = renderRect(state.scissor), .filter = if (state.filter == 0) .nearest else .bilinear,
            .blend = if (state.blend == 0) .replace else .over,
            .transfer = switch (state.transfer) { 0 => .identity, 1 => .decode_srgb, 2 => .encode_srgb, 3 => .color, else => unreachable },
            .color_program = input.color,
            .color = state.color, .opacity = @intCast(state.opacity), .grid = @bitCast(grid) };
        try result.validate();
        return result;
    }
    fn renderRect(value: r4os.abi.GfxRenderRect) render.Rect {
        return .{ .x = value.x, .y = value.y, .width = value.width, .height = value.height };
    }
    pub fn beginQueuedGraphicsUpload(self: *Owner, input: *render_queue.Owner) !void {
        try self.queuedGraphicsAdmission(input);
        try self.validateQueuedGraphics(input);
        if (input.phase != .upload) return error.Binding;
        if (try self.graphics_cache.reusePacketList(input.commands())) {
            if (self.graphics_cache.packet_reuses == 1) self.log("NVIDIA render-cache: packet-reuse=1 program-uploads={d} uploaded-bytes={d} reserved-bytes={d} budget={d}",
                .{self.graphics_cache.program_uploads,self.graphics_cache.uploaded_bytes,self.graphics_cache.reservedBytes(),render_cache.budget_bytes});
            return;
        }
        const channel = self.graphics_copy_channel orelse return error.State;
        return self.startGraphicsUpload(channel, .packet, input.commands(), input.deadline, true);
    }
    pub fn beginQueuedGraphicsDraw(self: *Owner, input: *render_queue.Owner) !void {
        try self.queuedGraphicsAdmission(input);
        try self.validateQueuedGraphics(input);
        if (input.phase != .draw or !(try self.graphics_cache.binding()).matches(input.commands())) return error.Binding;
        const memory = self.memory_api orelse return error.Api;
        const target = try self.queuedGraphicsResource(input.references[1]);
        const source = if (input.draws[0].source != null) try self.queuedGraphicsResource(input.references[0]) else null;
        try self.startGraphicsBarrier(self.graphics_channel.?, input.deadline, true);
        const work = &self.graphics_work.?;
        work.queued = true;
        work.resources.openQueued(memory, &self.graphics_cache, target, source) catch |err| {
            if (work.resources.failed) self.stop(err) else self.graphics_work = null;
            return err;
        };
        work.command = .{ .draw = work.resources.command.? };
    }
    pub fn cancelQueuedGraphicsAdmission(self: *Owner, input: *render_queue.Owner) !void {
        try self.queuedRender(input);
        // These admission helpers return AdmissionExpired only before they
        // create a sub-operation. Earlier slices already closed their exact
        // hardware receipts; no reservation, cache borrow or current DMA may
        // be acknowledged by the public queue's failed completion here.
        if ((input.phase != .upload and input.phase != .draw) or self.graphics_upload != null or
            self.graphics_work != null or self.graphics_cache.borrowed or self.graphics_cache.uploading != null)
            return error.Retained;
    }
    pub fn beginGraphicsDraw(self: *Owner, handle: ChannelHandle, target: BufferHandle, source: ?BufferHandle, deadline: u64) !void {
        const memory = self.memory_api orelse return error.Api;
        const dst = try self.graphicsResource(target);
        const src = if (source) |value| try self.graphicsResource(value) else null;
        try self.beginGraphicsBarrier(handle,deadline);
        const work = &self.graphics_work.?;
        work.resources.open(memory,&self.graphics_cache,dst,src) catch |err| {
            if (work.resources.failed) self.stop(err) else self.graphics_work = null;
            return err;
        };
        work.command = .{ .draw = work.resources.command.? };
    }
    pub fn validateGraphicsWork(self: *Owner) !void {
        const work = if (self.graphics_work) |*value| value else return error.State;
        switch (work.command) {
            .barrier => if (work.resources.self_address != 0) return error.Binding,
            .draw => |binding| if (work.resources.cache_owner != &self.graphics_cache or !work.resources.valid() or
                !std.meta.eql(work.resources.command.?,binding)) return error.Binding,
        }
        if (work.queued) {
            const queued = if (self.queued_render) |value| value else return error.State;
            const binding = switch (work.command) { .draw => |value| value, else => return error.Binding };
            const fifo = try self.findChannel(work.channel_handle);
            const info = fifo.info() orelse return error.State;
            if (self.graphics_channel == null or !std.meta.eql(work.channel_handle, self.graphics_channel.?) or
                fifo.state != .handed_off or info.config.engine != .graphics or info.config.context.epoch != self.epoch or
                info.config.object_class != self.graphics_cache.class or
                !std.meta.eql(work.resources.target.reference, queued.references[1]) or
                (binding.draw.source != null and !std.meta.eql(work.resources.source.reference, queued.references[0])))
                return error.Binding;
            // The sub-operation already borrowed its immutable command and
            // the canonical queue's exact mapping references. Revalidate that
            // retained binding even during cursor PIO; fresh operand admission
            // still needs queuedGraphicsAdmission/nativeAddressSpace above.
            try self.validateQueuedGraphicsInSpace(queued, info.config.context.vaspace);
            if (queued.phase != .draw_wait or !binding.matches(queued.commands())) return error.Binding;
        } else if (self.queued_render != null) return error.Binding;
    }
    /// Private graphics command, retained through physical completion or
    /// quarantine. USERD publication never counts as an execution receipt.
    pub fn beginGraphicsBarrier(self: *Owner, handle: ChannelHandle, deadline: u64) !void {
        return self.startGraphicsBarrier(handle, deadline, false);
    }
    fn startGraphicsBarrier(self: *Owner, handle: ChannelHandle, deadline: u64, queued: bool) !void {
        const current = try self.now();
        if (deadline == std.math.maxInt(u64)) return error.Deadline;
        if (deadline <= current) return if (queued) error.AdmissionExpired else error.Deadline;
        if (self.commandExchangeBusy() or self.executionAdmissionBusy() or (!queued and self.queued_render != null) or self.graph_closing) return error.Busy;
        const fifo = try self.findChannel(handle);
        const info = fifo.info() orelse return error.State;
        if (info.config.engine != .graphics or info.config.object_class != try self.graphicsClass() or info.config.graphics == null or info.config.graphics.?.golden or fifo.state != .handed_off or !fifo.ring.idle()) return error.Unsupported;
        if (queued) try self.channel.?.guardUnsubmitted(deadline) else try self.channel.?.guard(deadline);
        self.graphics_work = .{ .channel_handle = handle, .command = .barrier, .deadline = deadline };
    }
    pub fn receiveGraphics(self: *Owner, handle: ChannelHandle) !?GraphicsReceipt {
        _ = try self.findChannel(handle);
        const work = if (self.graphics_work) |*value| value else return error.State;
        if (!std.meta.eql(work.channel_handle, handle)) return error.Stale;
        const receipt = work.receipt orelse return null;
        self.graphics_work = null;
        return receipt;
    }
    fn advanceGraphics(self: *Owner, current: u64) !bool {
        const work = if (self.graphics_work) |*value| value else return false;
        if (work.receipt != null) return false;
        try self.validateGraphicsWork();
        const fifo = try self.findChannel(work.channel_handle);
        if (work.submitted) {
            if (work.diagnostic_timeout) {
                if (current >= work.deadline) return error.Deadline;
                return false;
            }
            if (try fifo.ring.poll() >= work.ticket.?.point) {
                if (!work.resources.close(true)) return error.Retained;
                work.receipt = .{ .channel = work.channel_handle, .point = work.ticket.?.point, .completed_ns = current };
                return true;
            }
            if (current >= work.deadline) return error.Deadline;
            return false;
        }
        if (current >= work.deadline) {
            // An expired public draw with no GR reservation never gave this
            // sub-operation to the GPU. Release only its validated CPU borrow;
            // the queue owner then returns a failed caller receipt. A ticket,
            // pending ring or private producer still needs the fault path.
            if (!work.queued or work.ticket != null or !fifo.ring.idle()) return error.Deadline;
            if (!work.resources.close(true)) return error.Retained;
            self.graphics_work = null;
            return true;
        }
        if (self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.buffer_active != null or
            self.display_engine_active or self.display_channel_active != null or self.mode_control_active or self.outputs.active() or
            self.sequence.self_address != 0 or self.channel.?.phase != .idle or self.channel.?.pending != null) return false;
        work.ticket = try fifo.prepareGraphics(work.command);
        (if (work.queued) self.device.?.submitQueuedGraphics(fifo, work.ticket.?, work.deadline)
            else self.device.?.submitGraphics(fifo, work.ticket.?, work.deadline)) catch |err| {
            if (err != error.AdmissionExpired or !work.queued) return err;
            try self.validateUnsubmittedAdmission();
            try fifo.ring.abortUnpublished(work.ticket.?);
            if (!work.resources.close(true)) return error.Retained;
            self.graphics_work = null;
            return true;
        };
        work.submitted = true;
        if (self.diagnostic_render_timeout and work.queued) {
            const queued = self.queued_render orelse return error.State;
            self.diagnostic_render_timeout = false;
            work.diagnostic_timeout = true;
            self.log("NVIDIA reset-probe: render-submitted epoch={d} timeline={d} point={d} GR-point={d} deadline={d} DMA=held completion-observation=withheld hardware-fault=no",
                .{self.epoch,queued.job.fence.timeline,queued.job.fence.point,work.ticket.?.point,work.deadline});
        }
        return true;
    }
    /// Private producers and authenticated common-queue jobs share the same
    /// physical publisher and retain acknowledged VA maps until GPU completion.
    pub fn beginPushBatch(self: *Owner, handle: ChannelHandle, pushes: []const batch_job.batch.Push,
        bindings: []const VirtualBindingHandle, deadline: u64) !void
    {
        if (self.queued_native != null or self.hasQueuedWork()) return error.Busy;
        return self.startPushBatch(handle, pushes, bindings, deadline, null);
    }
    pub fn beginQueuedPushBatch(self: *Owner, work: *native_queue.Job) !void {
        const index = self.active_work orelse return error.State;
        if (self.work_slots[index] != .native or self.queued_native != work or
            &self.work_slots[index].native != work or work.phase != .submit or self.copy_backend == null or
            !std.meta.eql(work.binding, self.copy_backend.?.binding)) return error.Stale;
        try work.validate(self);
        const deadline = if (work.job.deadline_ns != 0) work.job.deadline_ns else try std.math.add(u64, try self.now(), 3 * std.time.ns_per_s);
        return self.startPushBatch(try work.channel(), work.pushes(), work.bindings(), deadline, work.job.fence);
    }
    fn startPushBatch(self: *Owner, handle: ChannelHandle, pushes: []const batch_job.batch.Push,
        bindings: []const VirtualBindingHandle, deadline: u64, native_fence: ?r4os.abi.GfxFence) !void
    {
        const current = try self.now();
        if (deadline <= current or deadline == std.math.maxInt(u64)) return error.Deadline;
        if (self.commandExchangeBusy() or self.executionAdmissionBusy() or self.queued_render != null or self.graph_closing) return error.Busy;
        const fifo = try self.findChannel(handle);
        const info = fifo.info() orelse return error.State;
        if (info.config.engine == .none or fifo.state != .handed_off or !fifo.ring.idle() or
            (info.config.graphics != null and info.config.graphics.?.golden)) return error.Unsupported;
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        if (info.config.context.vaspace != space.handle) return error.Stale;
        try self.channel.?.guard(deadline);
        const heap = self.ctx.?.heap() orelse return error.Api;
        self.batch_work = .{ .channel_handle = handle, .deadline = deadline, .native_fence = native_fence };
        self.batch_work.?.resources.open(heap, &self.virtuals, space, pushes, bindings) catch |err| {
            if (self.batch_work.?.resources.self_address != 0) self.stop(err) else self.batch_work = null;
            return err;
        };
    }
    pub fn validatePushBatch(self: *Owner) !void {
        const work = if (self.batch_work) |*value| value else return error.State;
        if (work.native_fence) |fence| {
            const queued = self.queued_native orelse return error.Binding;
            const index = self.active_work orelse return error.Binding;
            if (self.work_slots[index] != .native or &self.work_slots[index].native != queued or
                queued.phase != .wait or !std.meta.eql(queued.job.fence, fence) or
                !std.meta.eql(try queued.channel(), work.channel_handle)) return error.Binding;
            try queued.validate(self);
        } else if (self.queued_native != null) return error.Binding;
        const fifo = try self.findChannel(work.channel_handle);
        if (work.resources.virtuals != &self.virtuals or work.resources.space.epoch != self.epoch or
            work.resources.space.handle != fifo.config.context.vaspace or fifo.state != .handed_off or
            fifo.config.engine == .none or (fifo.config.graphics != null and fifo.config.graphics.?.golden)) return error.Binding;
        try work.resources.validate();
    }
    pub fn receivePushBatch(self: *Owner, handle: ChannelHandle) !?GraphicsReceipt {
        _ = try self.findChannel(handle);
        const work = if (self.batch_work) |*value| value else return error.State;
        if (!std.meta.eql(handle, work.channel_handle)) return error.Stale;
        const receipt = work.receipt orelse return null;
        self.batch_work = null;
        return receipt;
    }
    fn advancePushBatch(self: *Owner, current: u64) !bool {
        const work = if (self.batch_work) |*value| value else return false;
        if (work.receipt != null) return false;
        const fifo = try self.findChannel(work.channel_handle);
        if (work.submitted) {
            if (try fifo.ring.poll() >= work.ticket.?.point) {
                if (!work.resources.close(true)) return error.Retained;
                work.receipt = .{ .channel = work.channel_handle, .point = work.ticket.?.point, .completed_ns = current };
                return true;
            }
            if (current >= work.deadline) return error.Deadline;
            return false;
        }
        try self.validatePushBatch();
        if (current >= work.deadline) return error.Deadline;
        if (self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.buffer_active != null or
            self.display_engine_active or self.display_channel_active != null or self.mode_control_active or self.outputs.active() or
            self.sequence.self_address != 0 or self.channel.?.phase != .idle or self.channel.?.pending != null) return false;
        work.ticket = try fifo.prepareBatch(try work.resources.commands());
        try self.device.?.submitBatch(fifo, work.ticket.?, work.deadline);
        work.submitted = true;
        return true;
    }
    fn advanceGraphicsUpload(self: *Owner, current: u64) !bool {
        const work = if (self.graphics_upload) |*value| value else return false;
        if (!work.operation.validState() or work.operation.cache_owner != &self.graphics_cache) return error.Stale;
        const fifo = try self.findChannel(work.channel);
        if (work.operation.submitted) {
            const point = try fifo.ring.poll();
            if (point >= work.operation.ticket.?.point) {
                try work.operation.complete(point); self.graphics_upload = null; return true;
            }
            if (current >= work.operation.deadline) return error.Deadline;
            return false;
        }
        if (current >= work.operation.deadline) {
            try work.operation.cancel(); self.graphics_upload = null; return true;
        }
        if (self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.buffer_active != null or
            self.display_engine_active or self.display_channel_active != null or self.mode_control_active or self.outputs.active() or
            self.sequence.self_address != 0 or self.channel.?.phase != .idle or self.channel.?.pending != null) return false;
        work.operation.ticket = try fifo.prepareCopy(try work.operation.transfer());
        (if (work.queued) self.device.?.submitQueuedUpload(fifo,work.operation.ticket.?,work.operation.deadline)
            else self.device.?.submitCopy(fifo,work.operation.ticket.?,work.operation.deadline)) catch |err| {
            if (err != error.AdmissionExpired or !work.queued) return err;
            try self.validateUnsubmittedAdmission();
            try fifo.ring.abortUnpublished(work.operation.ticket.?);
            work.operation.ticket = null;
            try work.operation.cancel();
            self.graphics_upload = null;
            return true;
        };
        work.operation.submitted = true;
        return true;
    }
    fn validateUnsubmittedAdmission(self: *Owner) !void {
        const channel = if (self.channel) |*value| value else return error.State;
        if (self.failure != null or self.device == null or self.device.?.failure != null or
            self.activeChannel() != channel or channel.phase != .idle or channel.pending != null or
            channel.request.len != 0 or channel.deadline != null or channel.in_lockdown or
            channel.session.state != .active or channel.session.pending != null or self.sequence.self_address != 0)
            return error.Retained;
    }
    pub fn retireExecutionChannel(self: *Owner, handle: ChannelHandle, deadline: u64, quiesced: bool) !void {
        if (self.copy_backend) |backend| if (backend.channel) |channel| if (std.meta.eql(channel, handle)) return error.Busy;
        if (self.presentation) |entry| if (std.meta.eql(entry.channel_handle, handle)) return error.Busy;
        const owner = try self.findChannel(handle);
        // Public GR jobs wait for the golden bootstrap to finish; none can
        // execute on its private initialization channel. Let that idle channel
        // retire without waiting on the jobs that depend on its retirement.
        // Application/regular channels retain the existing queue barrier.
        const golden_bootstrap = self.native_queues.graphics_waiting and owner.config.engine == .graphics and
            owner.config.graphics != null and owner.config.graphics.?.golden;
        if (self.copyBusy() or (self.hasQueuedWork() and !owner.allocationReleased() and
            !self.native_queues.retiring(handle) and !golden_bootstrap)) return error.Busy;
        if (self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        var token = try self.channel.?.handoff(deadline);
        owner.beginDestroy(&token, deadline, quiesced) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        self.fifo_active = handle.slot;
    }
    fn freeChannelSlot(self: *Owner, index: usize) !void {
        const slot = &self.fifos[index]; const heap = slot.heap orelse return error.Api;
        const owner = slot.owner orelse return error.State;
        if (owner.state != .finished or owner.namespace_live or owner.awaitingCollection()) return error.Retained;
        if (heap.release(slot.allocation.handle) != r4os.abi.driver_heap_ok) return error.Retained;
        slot.* = .{};
    }
    pub fn hasDeferredPresentations(self: *const Owner) bool {
        for (&self.deferred_presentations) |*slot| if (slot.* != null) return true;
        return false;
    }
    fn presentationWaiting(self: *Owner, job: r4os.abi.GfxDriverJob) !bool {
        const a = r4os.abi;
        if (job.operation != a.gfx_queue_operation_upload and job.operation != a.gfx_queue_operation_present) return false;
        const current = self.presentationForJob(job) catch return false;
        const window = current.window.slot - 1;
        // At most one partially composed image per output. Another output,
        // copy or render producer can still use the intervening quantum.
        for (&self.work_slots) |*slot| switch (slot.*) {
            .copy => |*work| if (work.presentation and work.output_window != null and work.output_window.? == window) return true,
            else => {},
        };
        // Invalid/stopped requests go through the usual completion path.
        if (!self.validPresentation(current) or self.outputPaused(window) or self.presentation_buffers == 0 or
            job.version != 1 or job.size < @offsetOf(a.GfxDriverJob, "render") or job.reserved0 != 0 or job.reserved1 != 0) return false;
        return self.readyImage(window) != null or self.presentationGroupCount(current) < self.presentation_buffers or
            (try self.acquireFrame(current)) == null;
    }
    fn takeDeferredPresentation(self: *Owner, now_ns: u64) !?DeferredPresentation {
        const start = self.deferred_cursor;
        for (0..16) |offset| {
            const index = start +% @as(u4, @intCast(offset));
            const value = self.deferred_presentations[index] orelse continue;
            if (now_ns < value.deadline and try self.presentationWaiting(value.job)) continue;
            self.deferred_presentations[index] = null;
            self.deferred_cursor = index +% 1;
            return value;
        }
        return null;
    }
    /// Take the canonical job directly from the common queue. No caller can
    /// supply source addresses, completion points or edited job extents.
    pub fn hasQueuedWork(self: *const Owner) bool { return self.work_schedule.count() != 0; }
    fn activateWork(self: *Owner) !bool {
        if (self.copy_job != null or self.queued_render != null or self.queued_native != null or self.active_work != null) return error.State;
        const index = self.work_schedule.choose() orelse return false;
        self.active_work = index;
        switch (self.work_slots[index]) {
            .copy => |*work| self.copy_job = work,
            .render => |*work| self.queued_render = work,
            .native => |*work| self.queued_native = work,
            .free => return error.Stale,
        }
        return true;
    }
    fn selectWork(self: *Owner) !void {
        // Only a newly admitted, unsubmitted job may enter this selector.
        self.copy_job = null; self.queued_render = null; self.queued_native = null; self.active_work = null;
        if (!try self.activateWork()) return error.State;
    }
    pub fn yieldWork(self: *Owner) !void {
        if (self.batch_work != null or self.graphics_upload != null or self.graphics_work != null or
            (if (self.copy_job) |work| work.submitted else false)) return error.Busy;
        try self.work_schedule.yield(self.active_work orelse return error.State);
        self.copy_job = null; self.queued_render = null; self.queued_native = null; self.active_work = null;
    }
    fn releaseWork(self: *Owner) !void {
        const index = self.active_work orelse return error.State;
        try self.work_schedule.release(index);
        self.copy_job = null; self.queued_render = null; self.queued_native = null; self.active_work = null;
        self.work_slots[index] = .free;
    }
    pub fn beginCopyWork(self: *Owner, handle: ChannelHandle, binding: r4os.abi.GfxBackendBinding, deadline: u64) !bool {
        if (self.refresh_quiescing) return error.Busy;
        const work_slot = self.work_schedule.free() orelse return error.Busy;
        const fifo = try self.findChannel(handle);
        const value = fifo.info() orelse return error.State;
        if (!value.config.system_userd or !fifo.ring.idle() or self.copyAdmissionBusy() or self.graphics_starting or self.graph_closing or self.display_engine_active or self.display_channel_active != null or
            self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.buffer_active != null or
            self.outputs.active() or self.sequence.self_address != 0 or self.channel.?.phase != .idle or self.channel.?.in_lockdown) return error.Busy;
        if (self.frame_setup != null) return error.Busy;
        try self.channel.?.guard(deadline);
        const a = r4os.abi;
        if (binding.version != 1 or binding.size < @sizeOf(a.GfxBackendBinding) or binding.adapter_id != self.adapter_id or
            binding.milestone != a.gfx_queue_milestone_device_execution or binding.device_generation == 0 or binding.reset_generation == 0) return error.Descriptor;
        const queue = (if (self.copy_backend) |backend| @as(?r4os.driver_queue.Context, backend.queue) else self.ctx.?.graphicsQueue()) orelse return error.Api;
        const memory = self.memory_api orelse return error.Api;
        if (queue.table.version != 1 or queue.table.size < @offsetOf(a.GfxDriverQueueApi, "unregister_backend") + 8 or
            queue.table.unregister_backend == 0) return error.Api;
        if (self.copy_backend) |*backend| {
            if (!std.meta.eql(backend.binding, binding) or !std.meta.eql(backend.queue.table, queue.table)) return error.Stale;
        }
        var job: a.GfxDriverJob = .{};
        var work_deadline = deadline;
        const now_ns = try self.now();
        const result = if (try self.takeDeferredPresentation(now_ns)) |deferred| blk: {
            job = deferred.job; work_deadline = deferred.deadline;
            break :blk a.gfx_queue_ok;
        } else queue.take(&binding, &job);
        if (result != a.gfx_queue_ok and result != a.gfx_queue_error_busy and job.fence.timeline == 0) return error.Queue;
        if (self.copy_backend == null) self.copy_backend = .{ .queue = queue, .binding = binding };
        if (result == a.gfx_queue_error_busy and job.fence.timeline == 0) return false;
        if (result == a.gfx_queue_ok and job.operation == a.gfx_queue_operation_native) {
            if (!self.native_queues.ready()) {
                if (queue.complete(&job.fence, a.gfx_queue_result_failed, 1) != 1) return error.Retained;
                return true;
            }
            try self.work_schedule.admit(work_slot, job);
            self.work_slots[work_slot] = .{ .native = .{} };
            self.active_work = work_slot;
            self.queued_native = &self.work_slots[work_slot].native;
            self.queued_native.?.open(self, queue, binding, job) catch |err| { self.stop(err); return err; };
            try self.selectWork();
            return true;
        }
        if (job.deadline_ns != 0) work_deadline = @min(work_deadline, job.deadline_ns);
        if (result == a.gfx_queue_ok and now_ns < work_deadline and try self.presentationWaiting(job)) {
            for (&self.deferred_presentations) |*slot| if (slot.* == null) {
                slot.* = .{ .job = job, .deadline = work_deadline };
                return true;
            };
            // Bounded backpressure. Nothing has been submitted or imported;
            // completing this claimed job releases only its queue retention.
            if (queue.complete(&job.fence, a.gfx_queue_result_cancelled, 1) != a.gfx_queue_ok) return error.Retained;
            return true;
        }
        if (result == a.gfx_queue_ok and job.operation == a.gfx_queue_operation_direct_present) {
            const current = self.presentationForJob(job) catch {
                if (queue.complete(&job.fence, a.gfx_queue_result_failed, 1) != a.gfx_queue_ok) return error.Retained;
                return true;
            };
            // Additional heads advertise only copied presentation until their
            // independent direct-image retirement path is wired as well.
            if (!self.directOutputAvailable(current.window.slot - 1) or !queue.supportsScanout() or !self.validPresentation(current) or self.outputPaused(current.window.slot - 1) or
                job.version != 1 or job.size < @offsetOf(a.GfxDriverJob, "producer_kind") or job.reserved0 != 0 or job.reserved1 != 0 or
                job.fence.adapter_id != binding.adapter_id or job.fence.device_generation != binding.device_generation or
                job.fence.reset_generation != binding.reset_generation or job.fence.timeline == 0 or job.fence.point == 0 or
                job.source_offset != 0 or job.target_offset != 0 or job.target_pitch != 0 or !std.meta.eql(job.target_buffer, a.GfxBufferHandle{}) or
                !std.meta.eql(job.render, a.GfxRenderCommand{}) or job.byte_length != @as(u64, current.surface.descriptor.width) * 4 or
                job.row_count != current.surface.descriptor.height or job.source_pitch < job.byte_length or job.source_pitch & 63 != 0 or
                job.deadline_ns <= try self.now()) {
                if (queue.complete(&job.fence, a.gfx_queue_result_failed, 1) != a.gfx_queue_ok) return error.Retained;
                return true;
            }
            var free = false;
            for (&self.presentation_slots) |*slot| if (slot.* == null) { free = true; break; };
            if (!free) {
                if (queue.complete(&job.fence, a.gfx_queue_result_cancelled, 1) != a.gfx_queue_ok) return error.Retained;
                return true;
            }
            self.direct_work = .{ .job = job, .queue = queue, .memory = memory, .root = current.root,
                .channel = current.channel_handle, .window = current.window, .deadline = work_deadline };
            return true;
        }
        if (result == a.gfx_queue_ok and (job.operation == a.gfx_queue_operation_render or job.operation == a.gfx_queue_operation_render_list or job.operation == a.gfx_queue_operation_render_grid_list or job.operation == a.gfx_queue_operation_render_color_list or job.operation == a.gfx_queue_operation_render_color_grid_list)) {
            try self.work_schedule.admit(work_slot, job);
            self.work_slots[work_slot] = .{ .render = .{} };
            self.active_work = work_slot;
        self.queued_render = &self.work_slots[work_slot].render;
            self.queued_render.?.pixel_limit = self.work_schedule.render_limit;
            self.queued_render.?.open(queue, memory, binding, job, try self.now()) catch |err| { self.stop(err); return err; };
            try self.selectWork();
            return true;
        }
        try self.work_schedule.admit(work_slot, job);
        self.work_slots[work_slot] = .{ .copy = .{ .queue = queue, .memory = memory, .channel_handle = handle, .binding = binding,
            .job = job, .job_stamp = job, .deadline = work_deadline } };
        self.active_work = work_slot;
        self.copy_job = &self.work_slots[work_slot].copy;
        if (result != a.gfx_queue_ok or job.version != 1 or job.size < @offsetOf(a.GfxDriverJob, "row_count") or job.reserved0 != 0 or job.reserved1 != 0 or
            job.fence.adapter_id != binding.adapter_id or job.fence.timeline == 0 or job.fence.point == 0 or
            job.fence.device_generation != binding.device_generation or job.fence.reset_generation != binding.reset_generation) {
            self.stop(error.Descriptor); return error.Descriptor;
        }
        // Older kernels return only the original prefix, leaving zeroed tails.
        const image_present = job.operation == a.gfx_queue_operation_present;
        const rows = job.operation == a.gfx_queue_operation_copy_rows or image_present;
        if (rows and (job.size < @offsetOf(a.GfxDriverJob, "render") or job.row_count == 0 or job.source_pitch < job.byte_length or
            (!image_present and job.target_pitch < job.byte_length) or job.source_pitch > std.math.maxInt(u32) or job.target_pitch > std.math.maxInt(u32))) {
            try self.finishCopy(a.gfx_queue_result_failed); return true;
        }
        if (!rows and (job.row_count != 0 or job.source_pitch != 0 or job.target_pitch != 0)) { try self.finishCopy(a.gfx_queue_result_failed); return true; }
        if ((job.operation != a.gfx_queue_operation_copy and job.operation != a.gfx_queue_operation_upload and !rows) or
            job.byte_length == 0 or job.byte_length > std.math.maxInt(u32)) { try self.finishCopy(a.gfx_queue_result_failed); return true; }
        if ((job.operation == a.gfx_queue_operation_upload or image_present) and
            (!std.meta.eql(job.target_buffer, a.GfxBufferHandle{}) or job.target_offset != 0)) { try self.finishCopy(a.gfx_queue_result_failed); return true; }
        if (job.operation == a.gfx_queue_operation_upload or image_present) {
            // The desktop shadow remains a CPU-owned surface while headless.
            // Return this particular unsubmitted queue job without retaining
            // resources or claiming GPU execution; future events can repaint.
            const current = self.presentationForJob(job) catch { try self.finishCopy(a.gfx_queue_result_failed); return true; };
            const window = current.window.slot - 1;
            if (self.outputPaused(window)) { try self.finishCopy(a.gfx_queue_result_cancelled); return true; }
            if (!self.validPresentation(current) or !std.meta.eql(current.binding, binding) or
                current.channel_handle.slot != handle.slot or current.channel_handle.serial != handle.serial or
                (!image_present and !current.surface.matches(job))) { try self.finishCopy(a.gfx_queue_result_failed); return true; }
            if (image_present and (self.presentation_buffers < 2 or job.target_pitch != 0 or job.source_offset != 0 or
                job.byte_length != @as(u64, current.surface.descriptor.width) * 4 or
                job.row_count != current.surface.descriptor.height)) { try self.finishCopy(a.gfx_queue_result_failed); return true; }
            self.copy_job.?.presentation = true;
            self.copy_job.?.output_window = @intCast(window);
            if (self.presentation_buffers != 0) {
                const damage: present.Rect = if (image_present) .{ .x = 0, .y = 0,
                    .width = current.surface.descriptor.width, .height = current.surface.descriptor.height } else current.surface.damage(job) catch |err| {
                    if (err == error.Bounds) { try self.finishCopy(a.gfx_queue_result_failed); return true; }
                    return err;
                };
                for (&self.presentation_slots) |*slot| if (slot.*) |*entry| {
                    if (!std.meta.eql(entry.window, current.window) or !std.meta.eql(entry.surface.shadow.buffer, current.surface.shadow.buffer)) continue;
                    entry.damage = if (entry.damage) |prior| prior.merge(damage) else damage;
                };
                // Admission already checked an available image. Selection
                // stays resident once the queue's resources are imported.
            }
        }
        const resource_count: usize = if (self.copy_job.?.presentation) 1 else 2;
        for (0..resource_count) |i| {
            const reference = &self.copy_job.?.references[i];
            const status = queue.retainResource(&job.fence, @intCast(i), reference);
            if (status != a.gfx_queue_ok and reference.reference.id == 0) {
                try self.recordFault(.{ .source = .host, .kind = if (status == a.gfx_queue_error_capacity) .resource else .unknown,
                    .operation = .submit, .code = @as(u32, @bitCast(status)) });
                try self.finishCopy(a.gfx_queue_result_failed); return true;
            }
            if (status != a.gfx_queue_ok or reference.version != 1 or reference.size < @sizeOf(a.GfxBufferReference) or
                reference.flags != a.gfx_buffer_reference_mapping_only or reference.reserved0 != 0 or reference.reference.id == 0 or
                reference.reference.generation == 0 or reference.reference.reserved0 != 0 or
                !std.meta.eql(reference.buffer, if (i == 0) job.source_buffer else job.target_buffer)) {
                self.stop(error.Descriptor); return error.Descriptor;
            }
        }
        try self.selectWork();
        return true;
    }
    fn finishCopy(self: *Owner, result: u32) !void {
        self.retireCopy(result) catch |err| { self.stop(err); return err; };
    }
    fn retireCopy(self: *Owner, result: u32) !void {
        const work = self.copy_job.?;
        const a = r4os.abi;
        if (work.render_read.self_address != 0) {
            if (result == a.gfx_queue_result_complete) try work.render_read.complete(work.ticket.?.point)
            else try work.render_read.cancel();
        }
        if (work.queue.complete(&work.job.fence, result, 1) != a.gfx_queue_ok) return error.Retained;
        for (&work.references) |*reference| if (reference.reference.id != 0) {
            if (work.memory.bufferRelease(&reference.reference) != a.gfx_buffer_result_ok) return error.Retained;
            reference.* = .{};
        };
        if (result == a.gfx_queue_result_complete) {
            self.copy_completed +|= 1;
            const transfer = work.transfer orelse return error.State;
            self.copy_bytes +|= transfer.bytes *| @as(u64, if (transfer.rows) |rows| rows.count else 1);
            if (transfer.rows != null) self.copy_row_jobs +|= 1;
        }
        else if (work.presentation) {
            self.frames_rejected +|= 1;
            self.output_frames[work.output_window.?].rejected +|= 1;
        }
        try self.releaseWork();
    }
    fn advanceCopy(self: *Owner, current: u64) !bool {
        const work = if (self.copy_job) |value| value else return false;
        if (!std.meta.eql(work.job, work.job_stamp)) return error.Stale;
        const fifo = try self.findChannel(work.channel_handle);
        if (work.submitted) {
            if (work.diagnostic_timeout) {
                if (current >= work.deadline) return error.Timeout;
                return false;
            }
            if (try fifo.ring.poll() >= work.ticket.?.point) {
                work.copied = work.slice_end;
                if (work.copied < try execution_fifo.copy.wire.logicalBytes(work.transfer orelse return error.State)) {
                    work.submitted = false; work.ticket = null;
                    if (work.render_read.self_address != 0) { work.render_read.submitted = false; work.render_read.ticket = null; }
                    try self.yieldWork();
                    return true;
                }
                if (work.target_presentation) |entry| {
                    const window = entry.window.slot - 1;
                    if (self.readyImage(window) != null) return error.State;
                    entry.initial_point = work.ticket.?.point;
                    // An external composed image need not match the private
                    // CPU shadow. Its next incremental shadow upload must
                    // first replace the complete old external contents.
                    entry.damage = if (work.job.operation == r4os.abi.gfx_queue_operation_present)
                        .{ .x = 0, .y = 0, .width = entry.surface.descriptor.width, .height = entry.surface.descriptor.height } else null;
                    entry.render_fence = work.job.fence;
                    self.frames_rendered +|= 1;
                    self.output_frames[window].rendered +|= 1;
                    if (!self.outputPaused(window)) try self.setReadyImage(window, .{ .image = entry, .deadline = work.deadline });
                }
                try self.finishCopy(r4os.abi.gfx_queue_result_complete); return true;
            }
            if (current >= work.deadline) return error.Timeout; // Retain: a deadline is never quiescence.
            return false; // Continue processing GSP events while CE runs.
        }
        if (work.presentation and self.outputPaused(work.output_window orelse return error.State)) {
            try self.finishCopy(r4os.abi.gfx_queue_result_cancelled); return true;
        }
        if (current >= work.deadline) {
            try self.recordFault(diagnostics.host(.submit, error.Timeout, false));
            try self.finishCopy(r4os.abi.gfx_queue_result_failed); return true;
        }
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return false;
        if (work.presentation and self.presentation_buffers != 0 and work.target_presentation == null) {
            const current_image = try self.copyPresentation(work);
            if (self.readyImage(current_image.window.slot - 1) != null) return false;
            if (self.presentationGroupCount(current_image) < self.presentation_buffers) return false;
            work.target_presentation = (try self.acquireFrame(current_image)) orelse return false;
            self.frames_acquired +|= 1;
            self.output_frames[current_image.window.slot - 1].acquired +|= 1;
        }
        const resource_count: usize = if (work.presentation) 1 else 2;
        for (0..resource_count) |i| {
            if (work.addresses[i] != null) continue;
            const reference = work.references[i];
            for (self.native_buffers.items()) |*slot| if (slot.owner) |owner| {
                if (owner.queuedInfo(reference)) |value| {
                    if (value.epoch != self.epoch or owner.binding.space.handle != fifo.config.context.vaspace) return error.Stale;
                    work.addresses[i] = .{ .address = value.address, .bytes = value.logical_bytes }; break;
                }
            };
            if (work.addresses[i] != null) continue;
            if (work.mappings[i]) |handle| {
                const mapped = try self.bufferStatus(handle);
                if (mapped.state != .handed_off) return false;
                const value = mapped.info orelse { try self.finishCopy(r4os.abi.gfx_queue_result_failed); return true; };
                if (!std.meta.eql(value.buffer, reference.buffer) or value.epoch != self.epoch) return error.Stale;
                work.addresses[i] = .{ .address = value.address, .bytes = value.logical_bytes }; continue;
            }
            // Reuse confirmed whole-BO mappings across jobs; no repeated DMA
            // registration, heap allocation or RPC is needed for this case.
            for (self.buffers.items()) |*slot| if (slot.owner) |owner| {
                if (owner.info()) |value| if (std.meta.eql(value.buffer, reference.buffer) and value.epoch == self.epoch and owner.space.handle == fifo.config.context.vaspace) {
                    slot.last_used = self.copy_completed +| 1;
                    slot.last_used_ns = current;
                    work.addresses[i] = .{ .address = value.address, .bytes = value.logical_bytes }; break;
                };
            };
            if (work.addresses[i] != null) continue;
            work.mappings[i] = self.mapQueuedBuffer(&work.job.fence, @intCast(i), work.deadline) catch |err| {
                if (err == error.Retained or err == error.Descriptor or self.failure != null) return err;
                try self.finishCopy(r4os.abi.gfx_queue_result_failed); return true;
            };
            return true;
        }
        if (work.target_presentation) |entry| if (work.job.operation != r4os.abi.gfx_queue_operation_present and work.render_read.self_address == 0) {
            const address = work.addresses[0] orelse return error.State;
            var source: ?*buffer_mapping.Owner = null;
            for (self.buffers.items()) |*slot| if (slot.owner) |owner| if (owner.info()) |mapped| {
                if (std.meta.eql(mapped.buffer, work.job.source_buffer) and mapped.address == address.address and
                    mapped.logical_bytes == address.bytes and owner.space.handle == fifo.config.context.vaspace) { source = owner; break; }
            };
            try work.render_read.openRegion(&entry.surface, source orelse return error.Stale, work.deadline,
                if (entry.initial_point == 0) null else entry.damage orelse return error.State);
        };
        const transfer = self.copyTransfer() catch |err| {
            if (err == error.Bounds or err == error.Unsupported or err == error.Overflow) { try self.finishCopy(r4os.abi.gfx_queue_result_failed); return true; }
            return err;
        };
        if (work.transfer) |original| { if (!std.meta.eql(original, transfer)) return error.Stale; }
        else work.transfer = transfer;
        const part = try execution_fifo.copy.wire.slice(transfer, work.copied, self.work_schedule.copy_limit);
        work.slice_end = part.next;
        work.ticket = fifo.prepareCopy(part.transfer) catch |err| {
            if (err == error.Bounds or err == error.Unsupported or err == error.Exhausted) { try self.finishCopy(r4os.abi.gfx_queue_result_failed); return true; }
            return err;
        };
        if (work.render_read.self_address != 0) work.render_read.ticket = work.ticket;
        try self.device.?.submitCopy(fifo, work.ticket.?, work.deadline);
        if (work.render_read.self_address != 0) work.render_read.submitted = true;
        work.submitted = true;
        if (self.diagnostic_copy_timeout and !work.presentation) {
            self.diagnostic_copy_timeout = false;
            work.diagnostic_timeout = true;
            @import("gsp_mode_diagnostics.zig").write(&self.ctx.?,
                "NVIDIA reset-probe: submitted epoch={d} timeline={d} point={d} CE-point={d} deadline={d} DMA=held completion-observation=withheld hardware-fault=no",
                .{self.epoch,work.job.fence.timeline,work.job.fence.point,work.ticket.?.point,work.deadline});
        }
        return true;
    }
    pub fn copyTransfer(self: *Owner) !execution_fifo.copy.wire.Transfer {
        try self.validateCopyOverlap();
        const work = if (self.copy_job) |value| value else return error.State;
        if (!std.meta.eql(work.job, work.job_stamp)) return error.Stale;
        if (work.presentation) {
            const current = try self.copyPresentation(work);
            if (!self.validPresentation(current) or !std.meta.eql(work.references[0].buffer, work.job.source_buffer) or
                work.references[0].flags != r4os.abi.gfx_buffer_reference_mapping_only or
                !std.meta.eql(work.channel_handle, current.channel_handle)) return error.Stale;
            if (work.job.operation == r4os.abi.gfx_queue_operation_present) return self.copyImageToOutput(work);
            const source = work.addresses[0] orelse return error.State;
            const fifo = try self.findChannel(work.channel_handle);
            var confirmed = false;
            for (self.buffers.items()) |*slot| if (slot.owner) |owner| if (owner.info()) |value| {
                if (std.meta.eql(value.buffer, work.references[0].buffer) and value.epoch == self.epoch and
                    value.address == source.address and value.logical_bytes == source.bytes and owner.space.handle == fifo.config.context.vaspace)
                    confirmed = true;
            };
            if (!confirmed) return error.Stale;
            if (work.target_presentation) |entry| {
                if (!self.preparedPresentation(entry) or entry == current or
                    !std.meta.eql(entry.window, current.window) or !std.meta.eql(entry.surface.shadow.buffer, current.surface.shadow.buffer) or !work.render_read.valid() or
                    work.render_read.surface != &entry.surface or work.render_read.deadline != work.deadline or
                    !std.meta.eql(work.render_read.region, if (entry.initial_point == 0) null else entry.damage) or
                    !try self.display_resources_slot.owner.?.imageFinished(entry.window.slot, entry.surface.scanout.?.dma)) return error.Stale;
                return work.render_read.transfer();
            }
            return current.surface.transfer(work.job, source.address, source.bytes);
        }
        const job = &work.job;
        const rows: ?execution_fifo.copy.wire.Rows = if (job.operation == r4os.abi.gfx_queue_operation_copy_rows)
            .{ .count = job.row_count, .source_pitch = @intCast(job.source_pitch), .target_pitch = @intCast(job.target_pitch) } else null;
        const fifo = try self.findChannel(work.channel_handle);
        var operands: [2]@import("gsp_copy_layout.zig").Operand = undefined;
        for (work.addresses, [_]u64{job.source_offset,job.target_offset}, 0..) |source, offset, i| {
            const value = source orelse return error.State;
            var confirmed = false;
            var plan: ?vram.surface.Plan = null;
            for (self.native_buffers.items()) |*slot| if (slot.owner) |owner| if (owner.queuedInfo(work.references[i])) |info| {
                if (info.epoch != self.epoch or owner.binding.space.handle != fifo.config.context.vaspace or info.address != value.address or info.logical_bytes != value.bytes) return error.Stale;
                confirmed = true; plan = info.surface; break;
            };
            if (!confirmed) for (self.buffers.items()) |*slot| if (slot.owner) |owner| if (owner.info()) |info| {
                if (std.meta.eql(info.buffer, work.references[i].buffer) and info.epoch == self.epoch and owner.space.handle == fifo.config.context.vaspace and info.address == value.address and info.logical_bytes == value.bytes) {
                    confirmed = true; break;
                }
            };
            if (!confirmed) return error.Stale;
            operands[i] = try @import("gsp_copy_layout.zig").operand(value.address, value.bytes, offset, job.byte_length, rows, i == 1, plan);
        }
        return .{ .source = operands[0].address, .target = operands[1].address, .bytes = job.byte_length,
            .rows = rows, .source_block = operands[0].block, .target_block = operands[1].block };
    }
    fn copyImageToOutput(self: *Owner, work: *const CopyJob) !execution_fifo.copy.wire.Transfer {
        const entry = work.target_presentation orelse return error.State;
        const current = try self.copyPresentation(work);
        if (!self.preparedPresentation(entry) or entry == current or
            !std.meta.eql(entry.window, current.window) or
            !std.meta.eql(entry.surface.shadow.buffer, current.surface.shadow.buffer) or
            !try self.display_resources_slot.owner.?.imageFinished(entry.window.slot, entry.surface.scanout.?.dma)) return error.Stale;
        // Both CPU-rendered SYSTEM images and native images use the queue's
        // retained source. Its mapping identifies the actual CE address; no
        // private shadow alias or additional execution lease is invented.
        const a = r4os.abi;
        var descriptor: a.GfxBufferDescriptor = .{};
        if (work.memory.bufferDescribe(&work.references[0].reference, &descriptor) != a.gfx_buffer_result_ok or
            descriptor.version != 1 or descriptor.size < @sizeOf(a.GfxBufferDescriptor) or descriptor.reserved0 != 0)
            return error.Unsupported;
        const source = work.addresses[0] orelse return error.State;
        var plan: ?vram.surface.Plan = null;
        if (descriptor.location == a.gfx_buffer_location_device_local) {
            const resource = try self.queuedGraphicsResource(work.references[0]);
            _ = try render_job.image(resource, false);
            // bufferReserve binds the common BO to its confirmed driver
            // owner. Keep the immutable geometry plan unbound, but compare
            // every public descriptor field against that exact reservation.
            var bound_descriptor = resource.info.surface.descriptor;
            bound_descriptor.driver_owner = resource.driver_owner;
            if (!std.meta.eql(descriptor, bound_descriptor) or source.address != resource.info.address or
                source.bytes != resource.info.logical_bytes) return error.Stale;
            plan = resource.info.surface;
        } else if (descriptor.location == a.gfx_buffer_location_system) {
            if (descriptor.modifier != 0 or descriptor.adapter_id != 0 or descriptor.device_generation != 0 or
                descriptor.driver_owner != 0 or descriptor.usage & a.gfx_buffer_usage_transfer_source == 0) return error.Unsupported;
            const fifo = try self.findChannel(work.channel_handle);
            var confirmed = false;
            for (self.buffers.items()) |*slot| if (slot.owner) |owner| if (owner.info()) |info| {
                if (std.meta.eql(info.buffer, work.references[0].buffer) and info.epoch == self.epoch and
                    owner.space.handle == fifo.config.context.vaspace and info.address == source.address and
                    info.logical_bytes == source.bytes) { confirmed = true; break; }
            };
            if (!confirmed) return error.Stale;
        } else return error.Unsupported;
        const image = entry.surface.scanout.?;
        if (descriptor.format != image.format or descriptor.width != image.width or
            descriptor.height != image.height or descriptor.plane_count != 1 or descriptor.plane_offsets[0] != 0 or descriptor.byte_length != source.bytes or
            work.job.byte_length != @as(u64, image.width) * 4 or work.job.row_count != image.height or
            work.job.source_pitch != descriptor.plane_pitches[0] or work.job.target_pitch != 0 or
            work.job.source_offset != 0 or work.job.target_offset != 0) return error.Unsupported;
        const destination = entry.surface.target_stamp.?;
        const rows: execution_fifo.copy.wire.Rows = .{ .count = image.height,
            .source_pitch = @intCast(work.job.source_pitch), .target_pitch = image.pitch };
        const layout = @import("gsp_copy_layout.zig");
        const src = try layout.operand(source.address, source.bytes, 0, work.job.byte_length, rows, false, plan);
        const dst = try layout.operand(destination.address, destination.bytes, image.offset, work.job.byte_length, rows, true, null);
        return .{ .source = src.address, .target = dst.address, .bytes = work.job.byte_length,
            .rows = rows, .source_block = src.block };
    }
    fn advanceCursorUpload(self: *Owner, current: u64) !bool {
        const work = if (self.cursor_upload) |*value| value else return false;
        try self.validateCursorUpload();
        const fifo = try self.findChannel(work.channel);
        if (work.operation.phase == .submitted) {
            const point = try fifo.ring.poll();
            if (point >= work.operation.ticket.?.point) {
                try work.operation.complete(point);
                if (work.operation.phase == .complete) {
                    self.cursor_storage.?.uploaded[work.slot] = .{ .plan = work.operation.plan, .point = work.operation.last_point };
                    self.cursor_upload = null;
                }
                return true;
            }
            if (current >= work.operation.deadline) return error.Timeout;
            return false;
        }
        if (current >= work.operation.deadline) {
            try work.operation.cancel(); self.cursor_storage.?.upload_error = error.Timeout; self.cursor_upload = null; return true;
        }
        if (work.operation.phase == .preparing) {
            work.operation.prepare() catch |err| {
                if (err == error.Descriptor or err == error.Retained) return err;
                try work.operation.cancel(); self.cursor_storage.?.upload_error = err; self.cursor_upload = null;
            };
            return true;
        }
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return false;
        work.operation.ticket = try fifo.prepareCopy(try work.operation.transfer());
        try self.device.?.submitCopy(fifo, work.operation.ticket.?, work.operation.deadline);
        try work.operation.submitted(work.operation.ticket.?);
        return true;
    }
    fn advanceDisplayUpload(self: *Owner, current: u64) !bool {
        const work = if (self.display_upload_job) |*value| value else return false;
        const resources = self.display_resources_slot.owner orelse return error.State;
        const parent = if (self.display_engine_owner) |*value| value else return error.State;
        if (self.copy_job != null or !resources.valid() or !work.operation.valid()) return error.Stale;
        const identity = work.operation.purpose == .identity_lut;
        if (identity) {
            try self.validateIdentityLutUpload();
        } else {
            if (work.operation.table != &resources.table or work.operation.target != &parent.instance_storage) return error.Stale;
            try self.validateDisplayTableUpdate();
        }
        const fifo = try self.findChannel(work.channel_handle);
        if (work.operation.phase == .submitted) {
            const point = try fifo.ring.poll();
            if (point >= work.operation.ticket.?.point) {
                work.operation.complete(point) catch |err| {
                    if (identity) self.log("NVIDIA identity-lut: failed={s} readback={} actual-crc={x} expected-crc={x} first-difference={?}",
                        .{@errorName(err),work.operation.readback_started,work.operation.readback_actual_crc,work.operation.readback_expected_crc,work.operation.readback_difference})
                    else if (work.operation.readback_requested)
                        self.log("NVIDIA cursor-table265: revision={d} failed={s} readback={} actual-crc={x} expected-crc={x} first-difference={?}",
                            .{work.operation.revision,@errorName(err),work.operation.readback_started,
                                work.operation.readback_actual_crc,work.operation.readback_expected_crc,work.operation.readback_difference});
                    return err;
                };
                if (work.operation.phase == .complete) {
                    if (identity) {
                        if (!work.operation.readback_verified) return error.State;
                        resources.identity_lut.?.ready = true;
                        self.log("NVIDIA identity-lut: bytes={d} gpu-copy=confirmed poisoned-readback=exact crc={x} root={x} epoch={d}",
                            .{work.operation.payloadBytes(),work.operation.readback_actual_crc,parent.binding.root,self.epoch});
                        self.display_upload_job = null;
                        return true;
                    }
                    if (work.operation.readback_verified)
                        self.log("NVIDIA cursor-table265: revision={d} bytes={d} live-exact=yes whole-actual-crc={x} whole-expected-crc={x} poisoned-before-CE=yes",
                            .{work.operation.revision,@import("gsp_display_table.zig").image_bytes,work.operation.readback_actual_crc,work.operation.readback_expected_crc});
                    try resources.finishRemoval(); self.display_upload_job = null;
                }
                return true;
            }
            if (current >= work.operation.deadline) return error.Timeout;
            return false;
        }
        if (current >= work.operation.deadline) {
            try work.operation.cancel(); self.display_upload_job = null;
            if (identity) return error.Timeout;
            try self.recordFault(diagnostics.host(.submit, error.Timeout, false)); return true;
        }
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return false;
        const transfer = try work.operation.transfer();
        work.operation.ticket = try fifo.prepareCopy(transfer);
        try self.device.?.submitCopy(fifo, work.operation.ticket.?, work.operation.deadline);
        try work.operation.submitted(work.operation.ticket.?); return true;
    }
    pub fn initialImageTransfer(self: *Owner) !execution_fifo.copy.wire.Transfer {
        const work = if (self.initial_image) |*value| value else return error.State;
        const entry = work.presentation;
        if (!self.preparedPresentation(entry)) return error.Stale;
        const source = try self.findBuffer(work.mapping orelse return error.State);
        const fifo = try self.findChannel(entry.channel_handle);
        if (entry.initial_point != 0 or work.operation.surface != &entry.surface or work.operation.source != source or
            source.space.handle != fifo.config.context.vaspace or work.operation.deadline != work.deadline) return error.Stale;
        if (self.display_images[entry.window.slot - 1]) |active| if (active.image.dma == entry.surface.scanout.?.dma) return error.Stale;
        return work.operation.transfer();
    }
    fn advanceInitialImage(self: *Owner, current: u64) !bool {
        const work = if (self.initial_image) |*value| value else return false;
        const entry = work.presentation;
        if (!self.preparedPresentation(entry)) return error.Stale;
        const fifo = try self.findChannel(entry.channel_handle);
        if (work.operation.submitted) {
            _ = try self.initialImageTransfer();
            const point = try fifo.ring.poll();
            if (point >= work.operation.ticket.?.point) {
                const completed = work.operation.ticket.?.point;
                try work.operation.complete(point);
                entry.initial_point = completed;
                entry.render_fence = .{};
                self.initial_image = null;
                self.log("NVIDIA gsp-initial-image: complete point={d} source-read=released mapping=retained scanout=uncommitted", .{completed});
                return true;
            }
            if (current >= work.deadline) return error.Timeout;
            return false;
        }
        if (current >= work.deadline) {
            if (work.operation.self_address != 0) try work.operation.cancel();
            entry.initial_failure = error.Timeout;
            self.initial_image = null;
            try self.recordFault(diagnostics.host(.submit, error.Timeout, false));
            return true;
        }
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return false;
        if (work.mapping == null) {
            // A cancelled pre-submit attempt can leave a confirmed mapping.
            // Keep it resident and reuse it for the retry and later frames.
            for (self.buffers.items(), 0..) |*slot, index| if (slot.owner) |source| if (source.info()) |value| {
                if (std.meta.eql(value.buffer, entry.surface.shadow.buffer) and value.epoch == self.epoch and
                    source.space.handle == fifo.config.context.vaspace) {
                    work.mapping = .{ .epoch = self.epoch, .serial = slot.serial, .slot = @intCast(index) }; break;
                }
            };
            if (work.mapping == null) {
                work.mapping = try self.mapBuffer(.initial_image, work.deadline); return true;
            }
        }
        const source = try self.findBuffer(work.mapping.?);
        if (source.state != .handed_off) return false;
        if (source.info() == null) {
            entry.initial_failure = error.Resource; self.initial_image = null; return true;
        }
        if (work.operation.self_address == 0) {
            work.operation.open(&entry.surface, source, work.deadline) catch |err| {
                if (work.operation.self_address == 0) { entry.initial_failure = err; self.initial_image = null; return true; }
                return err;
            };
            return true;
        }
        const transfer = try self.initialImageTransfer();
        work.operation.ticket = try fifo.prepareCopy(transfer);
        try self.device.?.submitCopy(fifo, work.operation.ticket.?, work.deadline);
        work.operation.submitted = true;
        return true;
    }
    pub fn displayWorkObsolete(self: *const Owner) bool {
        const work = self.display_work orelse return false;
        const admitted = work.admission orelse return false;
        return self.outputPaused(admitted.mode.window) and (self.outputs.invalidated or admitted.receiver_sequence != self.receiver_events.sequence);
    }
    /// Only an already admitted transaction may drain with its old signal.
    /// New commits continue to require a fresh receiver and IMP admission.
    pub fn displayWorkPlan(self: *Owner, root: DisplayEngineHandle, window: u32) !boot_mode.Plan {
        const work = if (self.display_work) |*value| value else return error.State;
        const admitted = if (work.admission) |*value| value else return error.State;
        if (root.epoch != self.epoch or admitted.mode.epoch != self.epoch or admitted.mode.window != window or
            work.boot_mode == null or !std.meta.eql(work.boot_mode.?, admitted.mode) or work.mode_receipt != admitted.receipt or
            work.link == null or !std.meta.eql(work.link.?.plan, admitted.link)) return error.Stale;
        _ = try self.findDisplayEngine(root);
        if (self.display_object == null or !std.meta.eql(admitted.link.object, self.display_object.?)) return error.Stale;
        if (self.displayWorkObsolete()) return admitted.mode;
        const expected = try self.admittedDisplayMode(root, try self.displayColorModePlan(root, window, admitted.mode.receiver_mode_id, admitted.mode.color, admitted.mode.color_pipeline));
        if (!std.meta.eql(expected, admitted.mode) or admitted.receipt != try self.modeAdmission(root, expected)) return error.Stale;
        return expected;
    }
    noinline fn validateDisplayLinkPlan(self: *Owner, expected: boot_mode.Plan) !void {
        const work = &self.display_work.?;
        const planned = if (self.displayWorkObsolete()) work.admission.?.link else try display_link.derive(expected, self.display_object.?, self.outputs.snapshot().?);
        if (!std.meta.eql(work.link.?.plan, planned)) return error.Stale;
    }
    pub fn validateDisplayLink(self: *Owner) !void {
        const work = if (self.display_work) |*value| value else return error.State;
        if (work.link_restore) |*restore| if (restore.control.mst_rebuild != null) return self.validateMstLinkRecovery();
        if (work.link_stop) |*cleanup| {
            try self.validateDisplayDetach();
            const previous = &work.detach.?;
            if (work.link_restore != null or !cleanup.stop_only or previous.link == null or
                !std.meta.eql(cleanup.plan, previous.link.?.plan) or work.core.phase != .complete or
                work.window.?.phase != .complete) return error.Stale;
            return;
        }
        const link = if (work.link) |*value| value else return error.State;
        const window = if (work.window) |*value| value else return error.State;
        const position = if (work.position) |*value| value else return error.State;
        const core = try self.findDisplayChannel(work.core.handle);
        const actual = try self.findDisplayChannel(window.handle);
        if (actual.parent != core.parent or actual.config.kind != .window or work.boot_mode == null) return error.Stale;
        const root: DisplayEngineHandle = .{ .epoch = self.epoch, .root = core.parent.binding.root };
        const expected = try self.displayWorkPlan(root, actual.config.index);
        try self.validateDisplayLinkPlan(expected);
        const previous_dsc = if (self.display_images[expected.window]) |*previous| if (previous.boot_mode) |*mode|
            mode.signal.dp_dsc != null or mode.signal.hdmi_dsc != null else false else false;
        if (work.core.config.clear_dsc != previous_dsc or window.config.clear_dsc or position.config.clear_dsc) return error.Stale;
        if (work.core.config.mst_sor_control != try @import("gsp_mst_sor.zig").control(expected, &self.display_images, false) or
            window.config.mst_sor_control != null or position.config.mst_sor_control != null) return error.Stale;
        if (work.core.config.preserve_windows != try self.displayPeerWindows(expected.window) or
            window.config.preserve_windows != 0 or position.config.preserve_windows != 0) return error.Stale;
        if (!std.meta.eql(work.boot_mode.?, expected) or
            !std.meta.eql(work.core.config.signal, @as(?boot_mode.Signal, expected.signal)) or
            window.config.scanout == null or window.config.scanout.?.width != expected.width or window.config.scanout.?.height != expected.height or
            !std.meta.eql(work.core.config.route, @as(?display_channel.push.commands.Route, .{ .head = expected.head, .window = expected.window }))) return error.Stale;
        if (work.link_restore) |*restore| {
            if (link.pending or work.core.phase != .prepare or window.phase != .prepare or position.phase != .prepare or
                work.core.ticket != null or window.ticket != null or position.ticket != null or
                restore.failure.receipt != link.last_receipt or !std.meta.eql(restore.failure.mode, expected) or
                restore.failure.candidate != window.config.scanout.?.dma or
                !std.meta.eql(restore.failure.previous, self.display_images[expected.window]) or
                (restore.failure.previous == null and !std.meta.eql(restore.failure.retired, self.display_retired[expected.window]))) return error.Stale;
            if (restore.control.stop_only) {
                const cleanup = if (link.plan.extended()) &link.plan else if (restore.failure.previous) |*previous| &previous.link.?.plan else return error.Stale;
                if (!std.meta.eql(cleanup.*, restore.control.plan)) return error.Stale;
            } else {
                const previous = if (restore.failure.previous) |*value| value else return error.Stale;
                if (previous.link == null or !previous.link.?.complete() or !std.meta.eql(previous.link.?.plan, restore.control.plan)) return error.Stale;
            }
            return;
        }
        switch (link.phase) {
            .before_scanout => if (work.core.phase != .prepare or window.phase != .prepare or position.phase != .prepare) return error.State,
            .after_scanout, .complete => if (work.core.phase != .complete or window.phase != .complete or position.phase != .complete) return error.State,
            .scanout => {},
        }
    }
    fn finishDisplayLinkFailure(self: *Owner, failed: *const DisplayLinkFailure) !void {
        if (self.display_link_failures[failed.mode.window] != null) return error.State;
        self.display_link_failures[failed.mode.window] = failed.*;
        const published = &self.display_link_failures[failed.mode.window].?;
        self.display_work = null;
        self.log("NVIDIA link: candidate={d} rejected={s} old-image=retained reply={d} restored={d}",
            .{published.candidate,@errorName(published.reason),published.receipt,published.restored_receipt});
    }
    noinline fn rollbackMstDisplayLink(self: *Owner, reason: anyerror) anyerror!void {
        const work = &self.display_work.?;
        const link = &work.link.?;
        const value = if (link.mst) |*item| item else return reason;
        const mode = work.boot_mode orelse return reason;
        if (work.ownershipInFlight() or work.link_restore != null or work.link_stop != null or link.pending or link.rpc_error or value.result != null or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown or
            value.request != null or value.sideband != null or value.root.mailbox_pending) return reason;
        if (value.core_point == 0) {
            if (work.core.phase != .prepare or work.window.?.phase != .prepare or work.position.?.phase != .prepare or
                work.core.ticket != null or work.window.?.ticket != null or work.position.?.ticket != null) return reason;
        } else if (work.core.phase != .complete or work.window.?.phase != .complete or work.position.?.phase != .complete or
            work.core.ticket.?.point != value.core_point or work.window.?.ticket.?.point != value.window_point) return reason;
        const failed: DisplayLinkFailure = .{ .mode = mode, .candidate = work.window.?.config.scanout.?.dma,
            .reason = reason, .receipt = link.last_receipt, .previous = self.display_images[mode.window], .retired = self.display_retired[mode.window] };
        if (failed.previous) |*previous| {
            const old = if (previous.link) |*value_link| value_link else return reason;
            if (!old.complete() or old.mst == null or previous.boot_mode == null or previous.position == null or
                previous.head != mode.head or !std.meta.eql(old.plan.mode.signal.mst, mode.signal.mst) or
                !std.meta.eql(old.plan.object, link.plan.object)) return error.Stale;
        }
        if (!link.mutated) {
            try link.cancelUnsubmitted();
            if (self.displayWorkObsolete()) { self.display_work = null; self.display_cancelled +|= 1; }
            else try self.finishDisplayLinkFailure(&failed);
            return;
        }
        value.failure = reason;
        work.link_restore = .{ .control = undefined, .failure = failed };
        errdefer work.link_restore = null;
        try work.link_restore.?.control.restoreMstInPlace(link, work.deadline);
        self.log("NVIDIA MST: candidate={d} rejected={s} restore=pending core={d} window={d}",
            .{ failed.candidate, @errorName(reason), value.core_point, value.window_point });
    }
    const MstRepair = struct {
        core: display_channel.push.commands.Config,
        window: display_channel.push.commands.Config,
        position: ?display_channel.push.commands.Config,
    };
    fn mstRepair(self: *Owner, offset: u16) !MstRepair {
        const work = &self.display_work.?;
        const restore = &work.link_restore.?;
        const mode = restore.failure.mode;
        const core = try self.findDisplayChannel(work.core.handle);
        const window = try self.findDisplayChannel(work.window.?.handle);
        const info = core.parent.info() orelse return error.State;
        if (core.config.kind != .core or core.config.index != 0 or window.config.kind != .window or window.config.index != mode.window or
            core.parent != window.parent or !core.ring.initialized or !window.ring.initialized) return error.Stale;
        const route: display_channel.push.commands.Route = .{ .head = mode.head, .window = mode.window };
        const previous = restore.failure.previous;
        const mask = if (previous) |image| try @import("gsp_mst_sor.zig").control(image.boot_mode.?, &self.display_images, false)
            else try @import("gsp_mst_sor.zig").withoutCandidate(mode, &self.display_images);
        return .{
            .core = .{ .kind = .core, .notifier = work.core.notifier.handle, .windows = info.hardware.windows, .initialize = false,
                .route = route, .signal = if (previous) |image| image.boot_mode.?.signal else null,
                .cursor_usage = if (previous) |image| image.boot_mode.?.cursor_size else 0,
                .detach_sor = if (previous == null) mode.signal.sor else null, .mst_sor_control = mask,
                .preserve_windows = if (previous != null) try self.displayPeerWindows(mode.window) else 0 },
            .window = .{ .kind = .window, .notifier = work.window.?.notifier.handle, .notifier_offset = offset,
                .windows = info.hardware.windows, .initialize = false, .route = route,
                .scanout = if (previous) |image| image.image else null, .with_position = previous != null,
                .detach_sor = if (previous == null) mode.signal.sor else null },
            .position = if (previous) |image| .{ .kind = .immediate, .notifier = 0, .windows = info.hardware.windows,
                .initialize = false, .route = route, .position = image.position.?.point } else null,
        };
    }
    /// Recovery keeps the original admission/failure immutable while the
    /// ordinary submissions may now contain the replacement Core/Window.
    pub fn validateMstLinkRecovery(self: *Owner) !void {
        const work = if (self.display_work) |*value| value else return error.State;
        const restore = if (work.link_restore) |*value| value else return error.State;
        const rebuild = if (restore.control.mst_rebuild) |*value| value else return error.State;
        const failed = restore.failure;
        const link = if (work.link) |*value| value else return error.Stale;
        const original = if (link.mst) |*value| value else return error.Stale;
        if (work.detach != null or work.link_stop != null or work.cursor != null or work.refresh != null or restore.abandoned or
            work.admission == null or work.boot_mode == null or work.window == null or link.pending or original.failure == null or
            failed.receipt != link.last_receipt or failed.receipt == 0 or !std.meta.eql(failed.mode, work.boot_mode.?) or
            !std.meta.eql(work.admission.?.mode, failed.mode) or !std.meta.eql(work.admission.?.link, link.plan) or
            !std.meta.eql(restore.control.plan, link.plan) or !std.meta.eql(rebuild.plan, original.plan) or
            rebuild.root != original.root or rebuild.ids != &self.outputs.mst_store.registry or rebuild.deadline != work.deadline or
            rebuild.candidate_core != original.core_point or rebuild.candidate_window != original.window_point or
            !std.meta.eql(failed.previous, self.display_images[failed.mode.window]) or
            (failed.previous == null and !std.meta.eql(failed.retired, self.display_retired[failed.mode.window]))) return error.Stale;
        const resources = self.display_resources_slot.owner orelse return error.State;
        if (work.core.handle.slot != 0 or work.window.?.handle.slot != failed.mode.window + 1 or
            resources.publishedNotifier(0) != work.core.notifier or resources.publishedNotifier(work.window.?.handle.slot) != work.window.?.notifier or
            resources.publishedImage(work.window.?.handle.slot, failed.candidate) == null) return error.Stale;
        if (failed.previous) |image| if (!std.meta.eql(resources.publishedImage(work.window.?.handle.slot, image.image.dma), image.image)) return error.Stale;
        if (rebuild.stage != .complete) try rebuild.root.transaction.validate(rebuild.token, &rebuild.root.live);
        if (!restore.scanout_replaced) {
            const phase: DisplayPhase = if (original.core_point == 0) .prepare else .complete;
            if (restore.repair_offset != null or work.core.phase != phase or work.window.?.phase != phase or work.position == null or
                work.position.?.phase != phase or work.window.?.config.scanout == null or work.window.?.config.scanout.?.dma != failed.candidate or
                !std.meta.eql(work.core.config.signal, @as(?boot_mode.Signal, failed.mode.signal))) return error.Stale;
            return;
        }
        if (original.core_point == 0 or original.window_point == 0 or restore.repair_offset == null) return error.Stale;
        const expected = try self.mstRepair(restore.repair_offset.?);
        if (!std.meta.eql(expected.core, work.core.config) or !std.meta.eql(expected.window, work.window.?.config) or
            !std.meta.eql(expected.position, if (work.position) |part| @as(?display_channel.push.commands.Config, part.config) else null)) return error.Stale;
        if (work.position) |part| if (failed.previous == null or !std.meta.eql(part.handle, failed.previous.?.position.?.handle)) return error.Stale;
        if (restore.control.phase != .scanout and (work.core.phase != .complete or work.window.?.phase != .complete or
            (if (work.position) |part| part.phase != .complete else false))) return error.Stale;
    }
    noinline fn advanceMstLinkRecovery(self: *Owner, current: u64) !Progress {
        const work = &self.display_work.?;
        const restore = &work.link_restore.?;
        const link = &restore.control;
        const rebuild = &link.mst_rebuild.?;
        if (link.phase == .scanout) {
            if (rebuild.candidate_core == 0) {
                const previous = restore.failure.previous;
                try link.rebuildScanout(.{ .attached = previous != null,
                    .core_point = if (previous) |image| image.core_point else 0,
                    .window_point = if (previous) |image| image.window_point else 0 });
                return .progress;
            }
            if (!restore.scanout_replaced) {
                const offset = try work.window.?.notifier.nextWindowOffset();
                const config = try self.mstRepair(offset);
                work.core.config = config.core; work.core.phase = .prepare; work.core.ticket = null;
                work.window.?.config = config.window; work.window.?.phase = .prepare; work.window.?.ticket = null;
                if (config.position) |value| work.position = .{ .handle = restore.failure.previous.?.position.?.handle, .config = value }
                else work.position = null;
                restore.repair_offset = offset; restore.scanout_replaced = true;
                return .progress;
            }
            if (work.position) |*part| if (part.phase == .prepare or part.phase == .rewind)
                return if (try self.advanceDisplayPosition(part, work.deadline, current)) .progress else .idle;
            if (work.window.?.phase == .prepare or work.window.?.phase == .rewind)
                return if (try self.advanceDisplaySubmission(&work.window.?, work.deadline, current)) .progress else .idle;
            var advanced = try self.advanceDisplaySubmission(&work.core, work.deadline, current);
            if (work.core.phase != .complete) return if (advanced) .progress else .idle;
            advanced = try self.advanceDisplaySubmission(&work.window.?, work.deadline, current) or advanced;
            if (work.window.?.phase != .complete) return if (advanced) .progress else .idle;
            if (work.position) |*part| {
                advanced = try self.advanceDisplayPosition(part, work.deadline, current) or advanced;
                if (part.phase != .complete) return if (advanced) .progress else .idle;
            }
            const resources = self.display_resources_slot.owner.?;
            if (!try resources.imageFinished(work.window.?.handle.slot, restore.failure.candidate)) return .idle;
            const core = try self.findDisplayChannel(work.core.handle);
            const armed = if (restore.failure.previous) |image|
                try self.device.?.readDisplaySharedSor(core, image.boot_mode.?, work.core.config.mst_sor_control.?, work.deadline) else
                try self.device.?.readDisplayDetached(core, restore.failure.mode, work.core.config.mst_sor_control, work.deadline);
            if (!armed) return .idle;
            try link.rebuildScanout(.{ .attached = restore.failure.previous != null,
                .core_point = work.core.ticket.?.point, .window_point = work.window.?.ticket.?.point });
            return .progress;
        }
        if (link.phase != .complete or rebuild.stage != .complete) return error.State;
        const failed = &restore.failure;
        for (&self.display_images, 0..) |*slot, index| if (slot.*) |*image| {
            if (image.link == null or image.link.?.mst == null or image.link.?.plan.transport.mst.root() != rebuild.token.root) continue;
            var updated = image.*;
            if (index == failed.mode.window and restore.scanout_replaced) {
                updated.core_point = work.core.ticket.?.point; updated.window_point = work.window.?.ticket.?.point;
                updated.position.?.sequence = work.position.?.ticket.?.point;
            }
            updated.link.?.mst = try rebuild.restoredImage(updated.link.?.plan.transport.mst, updated.core_point, updated.window_point);
            updated.link.?.receipt = rebuild.completion_receipt;
            if (!updated.link.?.complete()) return error.Completion;
            if (updated.window_point != image.window_point) try self.retainMstImage(updated);
            image.* = updated;
        };
        failed.previous = self.display_images[failed.mode.window];
        failed.restored_receipt = rebuild.completion_receipt;
        try self.finishDisplayLinkFailure(failed);
        return .progress;
    }
    /// A known reply before any channel submission may unwind its link
    /// setters. Transport uncertainty and failed restoration remain faults.
    noinline fn rollbackDisplayLink(self: *Owner, reason: anyerror) anyerror!void {
        const work = &self.display_work.?;
        const link = &work.link.?;
        if (link.operation == .mst) return self.rollbackMstDisplayLink(reason);
        const mode = work.boot_mode.?;
        if (work.ownershipInFlight() or work.link_restore != null or work.link_stop != null or link.pending or link.rpc_error or
            (link.phase != .before_scanout and !(link.phase == .scanout and self.displayWorkObsolete())) or !link.extended() or
            work.core.phase != .prepare or work.window.?.phase != .prepare or work.position.?.phase != .prepare or
            work.core.ticket != null or work.window.?.ticket != null or work.position.?.ticket != null or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown or
            (reason != error.Unsupported and reason != error.Bandwidth and reason != error.LinkTraining and reason != error.RmRejected and
                reason != error.Aux and reason != error.RetryExhausted and reason != error.Stale and reason != error.Pps)) return reason;
        const failed: DisplayLinkFailure = .{ .mode = mode, .candidate = work.window.?.config.scanout.?.dma,
            .reason = reason, .receipt = link.last_receipt, .previous = self.display_images[mode.window], .retired = self.display_retired[mode.window] };
        if (failed.previous) |*previous| {
            const old = if (previous.link) |*value_link| value_link else return reason;
            if (!old.complete() or previous.core_point == 0 or previous.window_point == 0 or previous.boot_mode == null or
                previous.boot_mode.?.epoch != self.epoch or std.meta.activeTag(old.plan.transport) != std.meta.activeTag(link.plan.transport) or
                old.plan.mode.output_generation != mode.output_generation or old.plan.mode.head != mode.head or old.plan.mode.window != mode.window or
                old.plan.mode.signal.sor != mode.signal.sor or old.plan.mode.signal.display_id != mode.signal.display_id or
                !std.meta.eql(old.plan.object, link.plan.object)) return reason;
            if (!self.displayWorkObsolete() and !std.meta.eql(old.plan,
                try display_link.derive(previous.boot_mode.?, self.display_object.?, self.outputs.snapshot().?))) return error.Stale;
        } else if (failed.retired) |*retired| {
            if (retired.epoch != self.epoch or retired.core_point == 0 or retired.window_point == 0) return reason;
        } else return reason;
        if (!link.mutated) {
            if (self.displayWorkObsolete()) { self.display_work = null; self.display_cancelled +|= 1; }
            else try self.finishDisplayLinkFailure(&failed);
            return;
        }
        const clear = if (link.plan.extended()) &link.plan else &failed.previous.?.link.?.plan;
        const abandoned = self.displayWorkObsolete();
        work.link_restore = .{ .control = undefined, .failure = failed, .abandoned = abandoned };
        errdefer work.link_restore = null;
        const control = &work.link_restore.?.control;
        if (!abandoned and failed.previous != null) control.initInPlace(failed.previous.?.link.?.plan)
        else try control.stopExtendedInPlace(clear.*, !abandoned);
        if (!control.stop_only) try control.clearPrevious(clear.*);
        self.log("NVIDIA link: candidate={d} rejected={s} restore=pending channels=unsubmitted", .{failed.candidate,@errorName(reason)});
    }
    noinline fn advanceDisplayLinkRecovery(self: *Owner) !Progress {
        const work = &self.display_work.?;
        const restore = &work.link_restore.?;
        const link = &restore.control;
        if (link.mst_rebuild != null) return self.advanceMstLinkRecovery(try self.now());
        if (link.phase == .scanout) {
            // The old Core/Window never received a candidate command. The
            // retained image proves this scanout; only link packets resume.
            if (restore.failure.previous == null or restore.abandoned) return error.State;
            try link.scanoutComplete();
            return .progress;
        }
        if (link.phase != .complete) return error.State;
        if (restore.abandoned) { self.display_work = null; self.display_cancelled +|= 1; return .progress; }
        const failed = &restore.failure;
        if (failed.previous) |*previous| {
            const proof: DisplayLink = .{ .plan = link.plan, .acknowledged = link.acknowledged, .receipt = link.last_receipt,
                .dp = link.dpResult(), .frl = link.frlResult() };
            if (!proof.complete()) return error.Completion;
            previous.link = proof;
            self.display_images[failed.mode.window] = previous.*;
        } else if (!link.stop_only or !link.cleared()) return error.Completion;
        failed.restored_receipt = link.last_receipt;
        try self.finishDisplayLinkFailure(failed);
        return .progress;
    }
    fn advanceDisplayLink(self: *Owner, current: u64) anyerror!Progress {
        return self.advanceDisplayLinkInner(current) catch |err| {
            if (self.display_work) |*active| if (active.linkControl()) |value| value.retainAmbiguous(err);
            return err;
        };
    }
    noinline fn advanceDisplayLinkInner(self: *Owner, current: u64) anyerror!Progress {
        const work = &self.display_work.?;
        var link = work.linkControl() orelse return error.State;
        const channel = &self.channel.?;
        try self.validateDisplayLink();
        if (current >= work.deadline) return error.Timeout;
        if (work.link_restore == null and work.link_stop == null and self.displayWorkObsolete() and
            link.pending and channel.phase == .prepared) {
            try channel.cancelPrepared(); link.pending = false;
        }
        if (work.link_restore) |*restore| if (restore.control.operation != .mst and self.displayWorkObsolete() and !restore.abandoned) {
            if (link.pending and channel.phase == .prepared) { try channel.cancelPrepared(); link.pending = false; }
            if (!link.pending) {
                const clear = if (work.link.?.plan.extended()) &work.link.?.plan else &restore.failure.previous.?.link.?.plan;
                try restore.control.stopExtendedInPlace(clear.*, false);
                restore.abandoned = true; link = &restore.control;
            }
        };
        if (work.link_stop) |*cleanup| if (cleanup.clear_dp) |*prior| {
            if (prior.receiver_present and (self.outputs.invalidated or self.receiver_events.pending or self.receiver_events.capturing)) {
                if (cleanup.pending and channel.phase == .prepared) { try channel.cancelPrepared(); cleanup.pending = false; }
                if (!cleanup.pending) {
                    try cleanup.stopExtendedInPlace(cleanup.plan, false);
                    link = cleanup;
                }
            }
        };
        if (work.link_restore != null and (link.phase == .scanout or link.phase == .complete)) {
            try self.validateDisplayLink();
            return self.advanceDisplayLinkRecovery();
        }
        if (work.link_stop != null and link.operation == .mst and link.phase == .scanout) {
            try link.rebuildScanout(.{ .attached = false, .core_point = work.core.ticket.?.point, .window_point = work.window.?.ticket.?.point });
            return .progress;
        }
        if (!link.pending) {
            if (work.link_restore == null and work.link_stop == null and self.displayWorkObsolete()) {
                if (link.phase == .before_scanout) {
                    if (link.mutated and link.extended()) try self.rollbackDisplayLink(error.LinkTraining)
                    else { try link.cancelUnsubmitted(); self.display_work = null; self.display_cancelled +|= 1; }
                } else if (link.phase == .after_scanout) {
                    if (link.operation == .mst) {
                        try self.rollbackDisplayLink(error.Stale);
                        return .progress;
                    }
                    // The interlocked image is now known but must be stopped;
                    // do not enable additional packets or clear AVMUTE.
                    link.phase = .complete;
                } else return error.State;
                return .progress;
            }
            if (!link.ready(current)) return .idle;
            if (!try @call(.never_inline, display_link.Work.prepare, .{ link, current })) return .idle;
            link.length = try @call(.never_inline, display_link.Work.encode, .{ link, &link.request });
            try channel.begin(display_link.function, link.request[0..link.length], work.deadline);
            link.pending = true;
            return .progress;
        }
        return self.receiveDisplayLink(link, current);
    }
    // The ACK payload copy is only live while consuming this reply, never
    // while revalidating the complete output/mode topology above.
    noinline fn receiveDisplayLink(self: *Owner, link: *display_link.Work, current: u64) !Progress {
        const work = &self.display_work.?;
        const channel = &self.channel.?;
        const received = try channel.poll(work.deadline);
        if (channel.phase == .waiting) try link.submitted();
        if (received) |dispatch| {
            if (!dispatch.response) {
                try self.notification(channel, dispatch, current); return .progress;
            }
            // Keep a bounded payload copy until the real ring ACK succeeds.
            // An ACK failure must not advance link/scanout admission.
            var payload: [display_link.max_bytes]u8 = undefined;
            if (dispatch.record.payload.len > payload.len) return error.Payload;
            @memcpy(payload[0..dispatch.record.payload.len], dispatch.record.payload);
            var record = dispatch.record;
            record.payload = payload[0..dispatch.record.payload.len];
            try channel.complete(dispatch.ticket);
            link.consume(record, dispatch.ticket.serial, current) catch |err| {
                if (work.link_restore == null and work.link_stop == null) {
                    self.rollbackDisplayLink(err) catch |failure| {
                        if (link.last_status) |status| if (status != 0) self.rmFailure(.display_channel, link.plan.object.display, status);
                        return failure;
                    };
                    return .progress;
                }
                if (link.last_status) |status| if (status != 0) self.rmFailure(.display_channel, link.plan.object.display, status);
                return err;
            };
            return .progress;
        }
        return if (channel.phase == .waiting) .idle else .progress;
    }
    noinline fn advanceAdaptiveControl(self: *Owner, current: u64) !Progress {
        try self.validateAdaptiveRefresh();
        const work = &self.display_work.?;
        const refresh = &work.refresh.?;
        const control = &refresh.control;
        const channel = &self.channel.?;
        if (current >= work.deadline) return error.Timeout;
        const obsolete = control.enabled and !self.adaptiveReceiverCurrent();
        if (obsolete and channel.phase == .prepared) {
            try channel.cancelPrepared(); control.pending = false;
        }
        if (obsolete and channel.phase == .idle) {
            try self.rollbackAdaptiveRefresh(error.Stale, current);
            return .progress;
        }
        if (control.phase == .complete) {
            if (!control.core_completed or control.core_point == 0 or control.last_receipt == 0 or
                work.core.phase != .complete or control.core_point != work.core.ticket.?.point) return error.Completion;
            self.refresh_results[control.plan.mode.window] = .{ .sequence = refresh.sequence, .plan = control.plan,
                .enabled = control.enabled, .core_point = control.core_point, .receipt = control.last_receipt, .failure = refresh.failure };
            try self.refresh_clocks[control.plan.mode.window].completed(control.enabled, current);
            self.log("NVIDIA refresh: head={d} enabled={} range-mHz={d}-{d} sequence={d} proof=link,RM,Core,LWSV",
                .{control.plan.mode.head, control.enabled, control.plan.refresh.range.min_millihz,
                    control.plan.refresh.range.max_millihz, refresh.sequence});
            self.display_work = null;
            return .progress;
        }
        if (control.phase == .core) return error.State;
        if (!control.pending) {
            if (!control.ready(current)) return .idle;
            control.length = try control.encode(&control.request);
            try channel.begin(refresh_control.function, control.request[0..control.length], work.deadline);
            control.pending = true;
            return .progress;
        }
        if (try channel.poll(work.deadline)) |dispatch| {
            if (!dispatch.response) { try self.notification(channel, dispatch, current); return .progress; }
            var payload: [refresh_control.max_bytes]u8 = undefined;
            if (dispatch.record.payload.len > payload.len) return error.Payload;
            @memcpy(payload[0..dispatch.record.payload.len], dispatch.record.payload);
            var record = dispatch.record; record.payload = payload[0..dispatch.record.payload.len];
            try channel.complete(dispatch.ticket);
            control.consume(record, dispatch.ticket.serial, current) catch |err| {
                if (control.enabled and refresh.failure == null and (err == error.RmRejected or err == error.Aux)) {
                    if (control.last_status != 0) try self.rejection(.display_channel, control.plan.object.display, control.last_status, null);
                    try self.rollbackAdaptiveRefresh(err, current);
                    return .progress;
                }
                if (control.last_status != 0) self.rmFailure(.display_channel, control.plan.object.display, control.last_status);
                return err;
            };
            return .progress;
        }
        return if (channel.phase == .waiting) .idle else .progress;
    }
    fn advanceDisplayOwnership(self: *Owner, current: u64) !bool {
        const work = &self.display_work.?;
        if (work.ownership) |*part| if (part.phase != .complete) {
            const progressed = try self.advanceDisplaySubmission(part, work.deadline, current);
            if (part.phase == .complete) {
                const route = part.config.route.?;
                for (&self.display_routes, 0..) |*entry, i| if (i != route.window and
                    part.config.windows & (@as(u32, 1) << @intCast(i)) != 0 and
                    part.config.preserve_windows & (@as(u8, 1) << @intCast(i)) == 0) { entry.* = null; };
                self.display_routes[route.window] = route.head;
                self.log("NVIDIA display-owner: head={d} window={d} point={d} proof=Core-notifier interlocks=none image=unsubmitted",
                    .{route.head,route.window,part.ticket.?.point});
            }
            return progressed;
        };
        return false;
    }
    noinline fn advanceDigitalWake(self: *Owner, current: u64) !Progress {
        const work = &self.display_work.?;
        if (!work.wake_before_link or work.wake_receipt != 0) return error.State;
        if (work.wake_failure != null) return .idle;
        if (current >= work.deadline) return error.Timeout;
        const link = if (work.link) |*value| value else return error.State;
        const window = link.plan.mode.window;
        try self.validateDigitalWakeBinding(window);
        const part = if (work.ownership) |*value| value else return error.State;
        if (part.phase != .complete) return if (try self.advanceDisplayOwnership(current)) .progress else .idle;
        if (work.wake_sequence == 0) {
            work.wake_sequence = self.beginPendingMonitorWake(window, work.deadline) catch |err| {
                if (err == error.Busy) return .idle;
                return err;
            };
            return .progress;
        }
        _ = try self.pendingMonitorPlan(window);
        const result = self.monitor_result orelse return error.Completion;
        if (result.sequence != work.wake_sequence or !result.on or result.receipt == 0 or
            result.receipt <= self.digital_monitor_sleep[window].?.receipt) return error.Completion;
        if (result.failure) |reason| {
            // Keep the exact head binding and unsubmitted ISO/LUT owners.
            // The public owner reports unavailable and requires a new On
            // intent; no internal retry or device-loss escalation is implied.
            work.wake_failure = reason;
        } else {
            work.wake_receipt = result.receipt;
            self.digital_monitor_sleep[window] = null;
            self.log("NVIDIA screen-wake: head={d} window={d} Core-owner={d} monitor-receipt={d} link=unsubmitted image=unsubmitted",
                .{link.plan.mode.head,window,part.ticket.?.point,result.receipt});
        }
        return .progress;
    }
    fn advanceDisplay(self: *Owner, current: u64) !bool {
        const work = if (self.display_work) |*value| value else return false;
        if (current >= work.deadline) return error.Timeout;
        if (work.refresh) |*refresh| {
            if (refresh.control.phase != .core) return error.State;
            try self.validateAdaptiveRefresh();
            if (refresh.control.enabled and !self.adaptiveReceiverCurrent() and work.core.phase == .prepare) {
                try self.rollbackAdaptiveRefresh(error.Stale, current);
                return true;
            }
        }
        if (work.detach != null) try self.validateDisplayDetach();
        if (work.link) |*link| {
            if (link.phase != .scanout and link.phase != .complete) return error.State;
            try self.validateDisplayLink();
            if (!work.ownershipInFlight() and self.displayWorkObsolete() and link.phase == .scanout and work.core.phase == .prepare and
                work.window.?.phase == .prepare and work.position.?.phase == .prepare) {
                if (link.mutated and link.extended()) try self.rollbackDisplayLink(error.LinkTraining)
                else { try link.cancelUnsubmitted(); self.display_work = null; self.display_cancelled +|= 1; }
                return true;
            }
        }
        if (work.ownership) |part| if (part.phase != .complete) return self.advanceDisplayOwnership(current);
        if (work.position) |*position| if (position.phase == .prepare or position.phase == .rewind)
            return self.advanceDisplayPosition(position, work.deadline, current);
        if (work.window) |*window| {
            // Submit both interlocked channels before waiting for either.
            // Waiting for Window BEGUN first would deadlock the core UPDATE.
            if (window.phase == .prepare or window.phase == .rewind)
                return self.advanceDisplaySubmission(window, work.deadline, current);
        }
        var progressed = try self.advanceDisplaySubmission(&work.core, work.deadline, current);
        if (progressed and work.core.phase != .complete) return true;
        if (work.window) |*window| {
            progressed = try self.advanceDisplaySubmission(window, work.deadline, current) or progressed;
            if (window.phase != .complete) {
                // A NULL ISO has no new visible image. GA106 can leave that
                // new record NOT_BEGUN even after Core and old FINISHED.
                // Only this exact detach may seek the independent physical
                // stop proof; ordinary frame admission remains unchanged.
                if (work.detach != null and work.core.phase == .complete and window.phase == .submitted)
                    return self.completeDisplayDetach(current, progressed);
                return progressed;
            }
        }
        if (work.core.phase != .complete) return progressed;
        if (work.refresh) |*refresh| {
            try refresh.control.submitted(work.core.ticket.?.point);
            try refresh.control.completed(work.core.ticket.?.point);
            return true;
        }
        if (work.detach != null) return self.completeDisplayDetach(current, progressed);

        if (work.cursor) |*cursor| {
            try self.validateCursorCommit();
            if (self.display_paused) {
                // Core completion drains the command. Both cursor slots stay
                // held until the subsequent NULL/Core/ARM stop proves hide.
                self.display_work = null; self.display_cancelled +|= 1;
                return true;
            }
            const observed = self.headObservation(cursor.control.head) catch |err| { if (err == error.Busy) return false; return err; };
            if (cursor.baseline == null) { cursor.baseline = observed; cursor.completed_ns = current; return true; }
            if (observed.sequence <= cursor.baseline.?.sequence or observed.observed_ns < cursor.completed_ns) return progressed;
            const core = try self.findDisplayChannel(work.core.handle);
            if (!try self.device.?.readCursorImageArmed(core, cursor.control, work.deadline)) return progressed;
            const storage = &self.cursor_storage.?;
            storage.active = if (cursor.control.visible) @intCast(cursor.control.offset / cursor_image.max_bytes) else null;
            storage.control = cursor.control; storage.completed = cursor.sequence;
            self.log("NVIDIA cursor-image: ARM-confirmed head={d} sequence={d} Core-point={d} head-IRQ={d} visible={} size={d} hotspot={d},{d} dma={x}",
                .{cursor.control.head,cursor.sequence,work.core.ticket.?.point,observed.sequence,cursor.control.visible,
                    cursor.control.size,cursor.control.hotspot_x,cursor.control.hotspot_y,cursor.control.dma});
        }
        if (work.position) |*position| {
            progressed = try self.advanceDisplayPosition(position, work.deadline, current) or progressed;
            if (position.phase != .complete) return progressed;
        }
        if (work.link) |*link| if (link.phase == .scanout) {
            if (work.core.config.mst_sor_control) |wanted| {
                const core = try self.findDisplayChannel(work.core.handle);
                if (!try self.device.?.readDisplaySharedSor(core, work.boot_mode.?, wanted, work.deadline)) return progressed;
            }
            try link.scanoutCompleted(work.core.ticket.?.point, work.window.?.ticket.?.point); return true;
        };
        if (work.window) |*window| {
            if (work.boot_mode) |*plan| {
                const core = try self.findDisplayChannel(work.core.handle);
                const expected = try self.displayWorkPlan(.{ .epoch = self.epoch, .root = core.parent.binding.root }, window.config.route.?.window);
                if (!std.meta.eql(plan.*, expected) or !std.meta.eql(work.core.config.signal, @as(?boot_mode.Signal, expected.signal))) return error.Stale;
            }
            try self.publishCompletedDisplayImage();
        }
        if (work.link) |*link| if (link.dpResult()) |proof| {
            self.log("NVIDIA gsp-dp: display={x} head={d} lanes={d} rate={x} source-max={x} sink-max={x} enhanced={} attempts={d} TU=64 watermark={d} hblank={d} vblank={d} audio48k={} receipt={d}",
                .{link.plan.mode.signal.display_id, link.plan.mode.head, proof.config.lanes, proof.config.rate, proof.source.rate, proof.sink.rate,
                    proof.sink.enhanced, proof.attempts, proof.stream.watermark, proof.stream.hblank, proof.stream.vblank, proof.stream.audio_48k, link.last_receipt});
            self.logBytes("dp-dpcd", link.plan.mode.signal.display_id, &proof.dpcd);
            self.logBytes("dp-lanes", link.plan.mode.signal.display_id, &proof.lane_status);
        };
        self.display_work = null; return true;
    }
    // Completion snapshots are only needed after both display channels
    // finish; they must not occupy the stack during admission revalidation.
    noinline fn completeDisplayDetach(self: *Owner, current: u64, progressed: bool) !bool {
        const work = &self.display_work.?;
        const previous = work.detach.?;
        const window = work.window.?;
        const mode = previous.boot_mode.?;
        const resources = self.display_resources_slot.owner.?;
        if (!try resources.imageFinished(window.handle.slot, previous.image.dma)) return progressed;
        if (work.core.phase != .complete or work.core.ticket == null or window.ticket == null or
            (window.phase != .submitted and window.phase != .complete)) return error.State;
        const window_owner = try self.findDisplayChannel(window.handle);
        if (window.phase == .submitted) {
            if (window.notifier.point != window.ticket.?.point or window.notifier.deadline != work.deadline or
                window_owner.ring.pending == null or !window_owner.ring.matchesPublished(window.ticket.?, window.config)) return error.Stale;
            if ((try window.notifier.observedWord()) >> 30 == 3) return error.Completion;
            const consumed = (try self.device.?.readDisplayCursor(window_owner, work.deadline)) orelse return progressed;
            if (consumed.put != window_owner.ring.put) return error.Completion;
            if (consumed.get != window.ticket.?.put) return progressed;
        } else if (window_owner.ring.pending != null or window_owner.ring.completed != window.ticket.?.point) return error.Stale;
        const core = try self.findDisplayChannel(work.core.handle);
        if (core.ring.pending != null or core.ring.completed != work.core.ticket.?.point or
            work.core.notifier.phase != .complete or work.core.notifier.point != work.core.ticket.?.point) return error.Stale;
        if (!try self.device.?.readDisplayDetached(core, mode, work.core.config.mst_sor_control, work.deadline)) return progressed;
        // Retire the exact NULL command only after Core, old-image FINISHED,
        // command GET and twice-observed NULL ARM. No new image timestamp or
        // CPU-written hardware FINISHED is produced. Keep all image storage.
        if (window.phase == .submitted) {
            try window_owner.ring.finish(window.ticket.?.point);
            work.window.?.phase = .complete;
        }
        try work.window.?.notifier.retireWindowNoImage(window.ticket.?.point, work.deadline);
        if (previous.link.?.plan.extended()) {
            if (work.link_stop == null) {
                // An HPD notification invalidates receiver identity. The
                // stopped Core and source FEC-off ACK still retire the
                // old route; its DSC setter must not touch a new sink.
                work.link_stop = @as(display_link.Work, undefined);
                errdefer work.link_stop = null;
                if (previous.link.?.mst) |proof| {
                    try work.link_stop.?.stopMstInPlace(previous.link.?.plan, proof,
                        .{ .head = mode.head, .window = mode.window, .dma = previous.image.dma,
                            .core_point = previous.core_point, .window_point = previous.window_point }, &self.outputs.mst_store, work.deadline);
                } else try work.link_stop.?.stopExtendedInPlace(previous.link.?.plan,
                    !self.outputs.invalidated and !self.receiver_events.pending and !self.receiver_events.capturing);
                return true;
            }
            const cleanup = &work.link_stop.?;
            if (!cleanup.stop_only or cleanup.phase != .complete or cleanup.pending or !cleanup.cleared()) return error.Completion;
            if (cleanup.mst_rebuild) |*rebuilt| if (!rebuilt.disconnected) { for (&self.display_images, 0..) |*slot, index| if (slot.*) |*image| {
                if (index == mode.window or image.link == null or image.link.?.mst == null or
                    image.link.?.plan.transport.mst.root() != rebuilt.token.root) continue;
                image.link.?.mst = try rebuilt.restoredImage(image.link.?.plan.transport.mst, image.core_point, image.window_point);
                image.link.?.receipt = rebuilt.completion_receipt;
                if (!image.link.?.complete()) return error.Completion;
            }; };
        }
        if (self.cursor_storage) |*storage| {
            if (storage.head == previous.head) {
                storage.active = null;
                storage.control = .{ .head = previous.head, .visible = false };
            }
        }
        self.display_retired[mode.window] = .{ .epoch = self.epoch, .image = previous,
            .core_point = work.core.ticket.?.point, .window_point = window.ticket.?.point, .observed_ns = current,
            .link_stop_receipt = if (work.link_stop) |*cleanup| cleanup.clear_receipt else 0 };
        if (mode.signal.mst) |stamp| try self.outputs.mst_store.registry.detached(stamp.handle, self.display_retired[mode.window].?);
        self.display_images[mode.window] = null;
        // Detach retires DMA consumers, not the Window->head assignment.
        // A later different-head assignment still takes the separate,
        // notifier-backed, non-interlocked ownership transaction.
        self.display_routes[mode.window] = previous.head;
        self.display_link_failures[mode.window] = null;
        self.display_work = null;
        self.log("NVIDIA output-detach: head={d} window={d} previous={d} proof=Core,old-Window-FINISHED,NULL-command,ARM shadow=retained", .{previous.head,mode.window,previous.image.dma});
        return true;
    }
    noinline fn publishCompletedDisplayImage(self: *Owner) !void {
        const work = &self.display_work.?;
        const window = &work.window.?;
        const route = window.config.route.?;
        if (work.wake_before_link and (work.wake_sequence == 0 or work.wake_receipt == 0 or work.wake_failure != null))
            return error.Completion;
        var mode = work.boot_mode;
        var link: ?DisplayLink = if (work.link) |*value| .{ .plan = value.plan, .acknowledged = value.acknowledged, .receipt = value.last_receipt,
            .dp = value.dpResult(), .frl = value.frlResult(), .mst = value.mstResult() } else null;
        var position: ?DisplayPosition = if (work.position) |value| .{ .handle = value.handle,
            .point = value.config.position.?, .sequence = value.ticket.?.point } else null;
        if (mode == null) if (self.display_images[route.window]) |*prior| {
            if (prior.head == route.head and prior.image.width == window.config.scanout.?.width and prior.image.height == window.config.scanout.?.height) {
                mode = prior.boot_mode;
                link = prior.link;
                if (position == null) position = prior.position;
            }
        };
        self.display_images[route.window] = .{ .image = window.config.scanout.?, .head = route.head,
            .core_point = work.core.ticket.?.point, .window_point = window.ticket.?.point, .boot_mode = mode,
            .mode_receipt = if (work.mode_receipt != 0) work.mode_receipt else if (self.display_images[route.window]) |prior| prior.mode_receipt else 0,
            .position = position, .link = link, .wake_sequence = work.wake_sequence, .wake_receipt = work.wake_receipt };
        try self.retainMstImage(self.display_images[route.window].?);
        self.display_retired[route.window] = null;
    }
    fn advanceDisplayFlip(self: *Owner, current: u64) !bool {
        const start = self.flip_cursor;
        for (0..8) |offset| {
            const index = start +% @as(u3, @intCast(offset));
            if (try self.advanceOutputFlip(index, current)) {
                self.flip_cursor = index +% 1;
                return true;
            }
        }
        return false;
    }
    fn advanceOutputFlip(self: *Owner, index: u3, current: u64) !bool {
        const work = self.displayFlip(index) orelse return false;
        // A failed Window remains a physical consumer. It owns neither CE
        // nor another head's Window, and its expired deadline is not reused.
        if (self.output_faults[index] != null) return false;
        try self.validateOutputFlip(index);
        if (current >= work.deadline) {
            if (work.window.phase == .prepare and work.window.ticket == null) {
                self.display_flips[index] = null; self.flip_cancelled +|= 1;
                return true;
            }
            if (!self.hasOtherOutput(index)) return error.Timeout;
            self.faultOutput(index, error.Timeout);
            return true;
        }
        const window = &work.window;
        if (self.outputPaused(index) and window.phase == .prepare and window.ticket == null) {
            self.display_flips[index] = null; self.flip_cancelled +|= 1;
            return true;
        }
        if (window.phase != .complete) {
            const preparing = window.phase == .prepare;
            if (preparing) {
                work.baseline = self.headObservation(work.receipt.head) catch |err| {
                    if (err == error.Busy) return false; return err;
                };
                work.receipt.submitted_ns = current;
            }
            const changed = try self.advanceDisplaySubmission(window, work.deadline, current);
            if (self.diagnostic_flip_irq_timeout and window.phase == .submitted) {
                self.diagnostic_flip_irq_timeout = false;
                work.diagnostic_irq_timeout = true;
                self.log("NVIDIA reset-probe: flip-submitted epoch={d} head={d} sequence={d} Window-point={d} deadline={d} DMA=held IRQ-observation=withheld IRQ-handler=unchanged hardware-fault=no",
                    .{self.epoch, work.receipt.head, work.receipt.sequence, window.ticket.?.point, work.deadline});
            }
            if (window.phase != .complete) return changed;
        }
        if (self.outputPaused(index) and work.receipt.begun_observed_ns == 0) {
            // Detaching does not wait for another head IRQ to claim visible
            // presentation. BEGUN identifies the image that retirement must
            // now stop; the previous image's FINISHED remains independent.
            if (!work.retiring_activation) {
                var active = work.previous;
                active.image = window.config.scanout.?; active.window_point = window.ticket.?.point;
                self.display_images[work.receipt.window] = active;
                try self.retainMstImage(active);
                if (work.presentation.direct) |*direct| if (!direct.handed_off) {
                    // BEGUN is a physical consumer even without a subsequent
                    // head IRQ. Transfer its lifetime so detach can proceed;
                    // no visible timestamp or statistics are manufactured.
                    if (self.copy_backend.?.queue.beginScanout(&direct.job.fence) != r4os.abi.gfx_queue_ok) return error.Retained;
                    direct.handed_off = true;
                };
                work.retiring_activation = true;
                return true;
            }
            if (!try self.display_resources_slot.owner.?.imageFinished(window.handle.slot, work.previous.image.dma)) return false;
            self.log("NVIDIA output-detach: flip={d} result=cancelled previous=finished current=held visibility=unclaimed", .{work.receipt.sequence});
            self.flip_cancelled +|= 1;
            self.display_flips[index] = null;
            return true;
        }
        if (work.receipt.begun_observed_ns == 0) {
            // The actual IRQ owner continues recording/acknowledging events.
            // Only this exact submitted flip ignores them until its existing
            // deadline; no visible receipt, FINISHED or quiescence is forged.
            if (work.diagnostic_irq_timeout) return false;
            const observed = self.headObservation(work.receipt.head) catch |err| {
                if (err == error.Busy) return false; return err;
            };
            // The IRQ can arrive on another CPU after this worker sampled
            // `current`. Keep the actual BEGUN and both images pending until
            // a fresh worker slice covers that observation; never publish a
            // visibility time earlier than its own IRQ or move the deadline.
            if (observed.sequence <= work.baseline.sequence or observed.observed_ns < work.receipt.submitted_ns or
                observed.observed_ns > current) return false;
            // A hardware Window BEGUN record proves activation. Head LAST_DATA
            // proves an IRQ was observed, without identifying an exact GPU
            // timestamp or deriving synthetic refresh ticks from CPU time.
            const result = window.notifier.result orelse return error.Completion;
            work.receipt.window_point = window.ticket.?.point;
            work.receipt.begun_gpu_timestamp = result.timestamp;
            work.receipt.begun_observed_ns = current;
            work.receipt.head_observation = observed;
            var active = work.previous;
            active.image = window.config.scanout.?; active.window_point = window.ticket.?.point;
            self.display_images[work.receipt.window] = active;
            try self.retainMstImage(active);
            if (work.ordinary) {
                // The selected alias follows visibility. The old image is
                // still held by this flip until its independent FINISHED.
                const previous = self.currentPresentation(index) orelse return error.State;
                if (!std.meta.eql(previous.surface.shadow.buffer, work.presentation.surface.shadow.buffer)) return error.Stale;
                work.presentation.pending = work.presentation.pending or previous.pending;
                previous.pending = false;
                self.selectPresentation(work.presentation);
            }
            if (work.presentation.direct) |*direct| if (!direct.handed_off) {
                if (self.copy_backend.?.queue.beginScanout(&direct.job.fence) != r4os.abi.gfx_queue_ok) return error.Retained;
                direct.handed_off = true;
            };
            self.flip_receipts[work.receipt.head] = work.receipt;
            self.flip_visible += 1;
            self.output_frames[index].visible += 1;
            return true;
        }
        const resources = self.display_resources_slot.owner orelse return error.State;
        if (!try resources.imageFinished(window.handle.slot, work.previous.image.dma)) return false;
        work.receipt.previous_released_ns = current;
        self.flip_receipts[work.receipt.head] = work.receipt;
        self.flip_released += 1;
        self.output_frames[index].released += 1;
        self.display_flips[index] = null;
        return true;
    }
    fn advancePresentFrame(self: *Owner, current: u64) !bool {
        const start = self.ready_cursor;
        for (0..8) |offset| {
            const window = start +% @as(u3, @intCast(offset));
            if (try self.advanceOutputFrame(window, current)) { self.ready_cursor = window +% 1; return true; }
        }
        return false;
    }
    fn advanceOutputFrame(self: *Owner, window: u3, current: u64) !bool {
        const ready = self.readyImage(window) orelse return false;
        if (self.outputPaused(window)) { try self.setReadyImage(window, null); return true; }
        if (current >= ready.deadline) {
            // CE is complete and this image was never submitted to Window.
            // Drop only the expired ready frame, without losing any output.
            try self.setReadyImage(window, null);
            self.frames_rejected +|= 1; self.output_frames[window].rejected +|= 1;
            return true;
        }
        if (self.displayFlip(window) != null) return false;
        const dma = ready.image.surface.scanout.?.dma;
        self.flipDisplayPresentationImage(dma, ready.deadline) catch |err| {
            if (err == error.Busy) return false; return err;
        };
        self.displayFlip(ready.image.window.slot - 1).?.ordinary = true;
        try self.setReadyImage(window, null);
        return true;
    }
    fn advanceDirect(self: *Owner, current: u64) !bool {
        if (self.direct_work) |*work| {
            const phase = work.phase;
            self.direct_step = true;
            defer self.direct_step = false;
            const done = work.step(self, current) catch |err| {
                if (err == error.Busy) return false;
                return err;
            };
            if (done) { self.direct_work = null; return true; }
            return self.direct_work.?.phase != phase;
        }
        if (self.copyBusy() or self.cursor_point != null or self.nativeObject() == null or self.graph_closing or
            self.display_channel_active != null or self.display_engine_active or self.buffer_active != null or self.virtuals.active_range != null or self.native_active != null or
            self.fifo_active != null or self.context_active != null or self.outputs.active() or self.sequence.self_address != 0 or
            self.channel.?.phase != .idle or self.channel.?.pending != null) return false;
        const backend = self.copy_backend orelse return false;
        const memory = self.memory_api orelse return error.Api;
        const resources = self.display_resources_slot.owner orelse return false;
        for (&self.presentation_slots) |*slot| if (slot.*) |*entry| if (entry.direct) |direct| {
            const dma = entry.surface.scanout.?.dma;
            const active = self.display_images[entry.window.slot - 1];
            if (active == null or active.?.image.dma != dma) {
                if (!try resources.imageFinished(entry.window.slot, dma)) continue;
                if (self.presentation == entry) {
                    // A detached head keeps a private shadow owner while the
                    // former direct source retires without claiming visibility.
                    if (!self.display_paused) return error.State;
                    const private = (try self.acquireFrame(entry)) orelse return false;
                    private.pending = private.pending or entry.pending; entry.pending = false;
                    self.presentation = private;
                }
                self.direct_work = .{ .job = direct.job, .queue = backend.queue, .memory = memory,
                    .root = entry.root, .channel = entry.channel_handle, .window = entry.window,
                    .deadline = current +| 3 * std.time.ns_per_s, .phase = .unregister, .dma = dma, .activated = direct.handed_off };
                return true;
            }
            if (self.display_paused or self.presentation != entry) continue;
            const requested = backend.queue.scanoutRetireRequested(&direct.job.fence);
            if (requested < 0) return error.Queue;
            if (requested == 0 and !direct.retire_requested) continue;
            const target = (try self.acquireFrame(entry)) orelse return false;
            self.direct_work = .{ .queue = backend.queue, .memory = memory, .root = entry.root,
                .channel = entry.channel_handle, .window = entry.window, .deadline = current +| 3 * std.time.ns_per_s,
                .phase = .restore, .source = entry, .target = target };
            self.frames_acquired +|= 1;
            self.output_frames[entry.window.slot - 1].acquired +|= 1;
            return true;
        };
        return false;
    }
    pub fn requirePrivatePresentation(self: *Owner) bool {
        if (self.presentation) |entry| if (entry.direct) |*direct| { direct.retire_requested = true; return false; };
        if (self.direct_work != null or self.hasDisplayFlips()) return false;
        for (&self.presentation_slots) |*slot| if (slot.*) |entry| if (entry.direct != null) return false;
        return true;
    }
    pub fn directRestoreTransfer(self: *Owner) !execution_fifo.copy.wire.Transfer {
        const work = self.direct_work orelse return error.State;
        if (work.phase != .restore or work.source == null or work.target == null or work.source == work.target or
            self.copy_job != null or self.hasDisplayFlips() or self.display_work != null or self.initial_image != null or
            self.cursor_upload != null or self.graphics_work != null or self.graphics_upload != null or self.display_upload_job != null) return error.State;
        const source = work.source.?; const target = work.target.?;
        if (self.presentation != source or source.direct == null or target.direct != null or
            !self.preparedPresentation(source) or !self.preparedPresentation(target) or
            !std.meta.eql(source.window, target.window) or !std.meta.eql(source.channel_handle, work.channel)) return error.Stale;
        const active = self.display_images[source.window.slot - 1] orelse return error.Stale;
        const src = source.surface.scanout.?; const dst = target.surface.scanout.?;
        if (!std.meta.eql(active.image, src) or src.width != dst.width or src.height != dst.height or src.format != dst.format or
            !try self.display_resources_slot.owner.?.imageFinished(target.window.slot, dst.dma)) return error.Stale;
        const source_storage = source.surface.target.?.info() orelse return error.Stale;
        const to = target.surface.target.?.info() orelse return error.Stale;
        if (source.surface.target.?.access != 0 or target.surface.target.?.access != 1 or source_storage.epoch != self.epoch or to.epoch != self.epoch or
            source_storage.adapter != to.adapter or source_storage.driver_owner != to.driver_owner or source_storage.driver_owner == 0) return error.Stale;
        const transfer: execution_fifo.copy.wire.Transfer = .{ .source = try std.math.add(u64, source_storage.address, src.offset),
            .target = try std.math.add(u64, to.address, dst.offset), .bytes = @as(u64, src.width) * 4,
            .rows = .{ .count = src.height, .source_pitch = src.pitch, .target_pitch = dst.pitch } };
        if (src.offset >= source_storage.bytes or dst.offset >= to.bytes or try transfer.span(false) > source_storage.bytes - src.offset or
            try transfer.span(true) > to.bytes - dst.offset) return error.Bounds;
        return transfer;
    }
    pub fn advanceDirectRestore(self: *Owner, work: *@import("gsp_direct_present.zig").Work, current: u64) !bool {
        if (!self.direct_step or self.direct_work == null or work != &self.direct_work.?) return error.State;
        const transfer = try self.directRestoreTransfer();
        const fifo = try self.findChannel(work.channel);
        if (work.submitted) {
            if (try fifo.ring.poll() < work.ticket.?.point) return false;
            const target = work.target.?;
            target.initial_point = work.ticket.?.point;
            target.damage = .{ .x = 0, .y = 0, .width = target.surface.descriptor.width, .height = target.surface.descriptor.height };
            target.render_fence = .{};
            self.frames_rendered +|= 1; self.copy_completed +|= 1;
            self.output_frames[target.window.slot - 1].rendered +|= 1;
            self.copy_bytes +|= transfer.bytes * transfer.rows.?.count;
            if (!self.display_paused) self.frame_ready = .{ .image = target, .deadline = work.deadline };
            return true;
        }
        if (current >= work.deadline) return error.Timeout;
        if (self.display_paused) return true;
        work.ticket = try fifo.prepareCopy(transfer);
        try self.device.?.submitCopy(fifo, work.ticket.?, work.deadline);
        work.submitted = true;
        return false;
    }
    fn advanceDisplayPosition(self: *Owner, work: *PositionSubmission, deadline: u64, current: u64) !bool {
        if (work.phase == .complete) return false;
        if (current >= deadline) return error.Timeout;
        const owner = try self.findDisplayChannel(work.handle);
        if (owner.info() == null or !owner.ring.valid() or owner.config.kind != .immediate) return error.Stale;
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return false;
        const cursors = (try self.device.?.readDisplayCursor(owner, deadline)) orelse return false;
        if (cursors.put != owner.ring.put) return error.Completion;
        if (work.phase == .submitted) {
            // No WIMM notifier exists. Both interlocked Window/Core notifiers
            // must have completed before observing GET and retiring this point.
            const pair = &self.display_work.?;
            if (pair.window == null or pair.core.phase != .complete or pair.window.?.phase != .complete) return error.State;
            if (cursors.get != work.ticket.?.put) return false;
            try owner.ring.finish(work.ticket.?.point); work.phase = .complete; return true;
        }
        if (work.phase == .rewind) {
            if (!try owner.ring.rewound(cursors.get)) return false;
            work.phase = .prepare; work.ticket = null; return true;
        }
        work.ticket = owner.ring.prepare(cursors.get, work.config) catch |err| {
            if (err == error.Busy) return false; return err;
        };
        try self.device.?.submitDisplay(owner, work.ticket.?, work.config, deadline);
        work.phase = if (work.ticket.?.kind == .rewind) .rewind else .submitted;
        return true;
    }
    fn advanceDisplaySubmission(self: *Owner, work: *DisplaySubmission, deadline: u64, current: u64) !bool {
        if (work.phase == .complete) return false;
        const owner = try self.findDisplayChannel(work.handle);
        const resources = self.display_resources_slot.owner orelse return error.State;
        if (owner.info() == null or resources.publishedNotifier(work.handle.slot) != work.notifier or !owner.ring.valid()) return error.Stale;
        if (work.phase == .submitted) {
            if (work.notifier.point != work.ticket.?.point or work.notifier.deadline != deadline) return error.Stale;
            const result = if (work.config.kind == .core) try work.notifier.poll() else
                if (work.config.detach_sor != null) try work.notifier.pollWindowDetached() else try work.notifier.pollWindow();
            if (result != null) {
                try owner.ring.finish(work.ticket.?.point); work.phase = .complete; return true;
            }
            if (current >= deadline) return error.Timeout;
            // One admitted late observation distinguishes a stalled command
            // consumer from a missing notifier. GET alone grants no progress.
            if (work.config.ownership_only and !work.pending_cursor_observed and deadline - current <= 250_000_000 and
                self.channel.?.phase == .idle and self.channel.?.pending == null and !self.channel.?.in_lockdown) {
                if (try self.device.?.readDisplayCursor(owner, deadline)) |cursors| {
                    work.pending_cursor_observed = true;
                    self.log("NVIDIA display-owner-wait: head={d} window={d} point={d} put={d} get={d} notifier={?x} image=unsubmitted",
                        .{work.config.route.?.head,work.config.route.?.window,work.ticket.?.point,cursors.put,cursors.get,
                            @as(?u32, work.notifier.observedWord() catch null)});
                    if (cursors.put != owner.ring.put) return error.Completion;
                    if (try self.device.?.readPendingDisplayOwner(owner,deadline)) |observed| {
                        self.log("NVIDIA display-owner-status: control={x} state={x} supervisor={x} dispatch={x} observation=read-only",
                            .{observed[0],observed[1],observed[2],observed[3]});
                    }
                }
            }
            return false;
        }
        if (current >= deadline) return error.Timeout;
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return false;
        const cursors = (try self.device.?.readDisplayCursor(owner, deadline)) orelse return false;
        if (cursors.put != owner.ring.put) return error.Completion;
        if (work.phase == .rewind) {
            if (!try owner.ring.rewound(cursors.get)) return false;
            work.phase = .prepare; work.ticket = null; return true;
        }
        if (work.config.cursor_image) |cursor| if (cursor.visible and self.cursor_storage.?.issued == 1 and !work.cursor_head_observed) {
            const observed = (try self.device.?.readCursorHeadState(owner, cursor, deadline)) orelse return false;
            work.cursor_head_observed = true;
            self.log("NVIDIA cursor-image-before: head={d} usage={x} contexts={x},{x} offsets={x},{x} present={x} control={x} composition={x} proof=two-identical-ARM-reads",
                .{cursor.head,observed[0],observed[1],observed[2],observed[3],observed[4],observed[5],observed[6],observed[7]});
            const index = resources.table.indexOf(0, cursor.dma) orelse return error.Stale;
            const descriptor = resources.table.entries[index].?;
            self.log("NVIDIA cursor-image-submit: dma={x} physical={x} bytes={d} offset={d} control={x} table={d}/{d} index={d} channel={d} Core-notifier={x}",
                .{cursor.dma,descriptor.physical,descriptor.bytes,cursor.offset,try cursor.word(),
                    resources.table.uploaded_revision,resources.table.revision,index,descriptor.channel,work.config.notifier});
            return true;
        };
        work.ticket = owner.ring.prepare(cursors.get, work.config) catch |err| {
            if (err == error.Busy) return false; return err;
        };
        const ticket = work.ticket.?;
        if (ticket.kind == .frame) {
            if (work.config.kind == .core) try work.notifier.arm(ticket.point, deadline)
            else {
                try work.notifier.armWindow(ticket.point, deadline, work.config.notifier_offset);
                if (work.config.scanout) |image| try resources.recordImageUse(work.handle.slot, image.dma, ticket.point, work.config.notifier_offset);
            }
        }
        try self.device.?.submitDisplay(owner, ticket, work.config, deadline);
        if (ticket.kind == .rewind) work.phase = .rewind else {
            try work.notifier.submitted(ticket.point, deadline); work.phase = .submitted;
            if (work.config.ownership_only) self.log("NVIDIA display-owner-submit: head={d} window={d} point={d} put={d} notifier={x} initialized={} interlocks=none image=unsubmitted",
                .{work.config.route.?.head,work.config.route.?.window,ticket.point,ticket.put,work.notifier.handle,owner.ring.initialized});
        }
        return true;
    }
    /// Called by the serialized native engine worker after queue.take. The
    /// common queue authenticates the full job/driver generation and supplies
    /// the reference; diagnostic buffer IDs are never imported here.
    pub fn mapQueuedBuffer(self: *Owner, fence: *const r4os.abi.GfxFence, which: u32, deadline: u64) !BufferHandle {
        return self.mapJobBuffer(fence, which, deadline) catch |err| { self.hostRejection(.mapping, err); return err; };
    }
    fn mapJobBuffer(self: *Owner, fence: *const r4os.abi.GfxFence, which: u32, deadline: u64) !BufferHandle {
        return self.mapBuffer(.{ .queue = .{ .fence = fence.*, .which = which } }, deadline);
    }
    /// Authenticate each loan independently, then reuse a public full-reference
    /// registration of that exact BO. Queue mapping-only cache entries cannot
    /// grant public access and are deliberately outside this sharing domain.
    pub fn mapVirtualReference(self: *Owner, reference: r4os.abi.GfxBufferReference, deadline: u64) !BufferHandle {
        try self.admitVirtual(deadline, false);
        const memory = self.memory_api orelse return error.Api;
        self.public_import.acquire(memory, self.epoch, reference) catch |err| {
            if (!self.public_import.empty()) self.stop(err);
            return err;
        };
        for (self.buffers.items(), 0..) |*slot, index| {
            if (slot.public_users == 0) continue;
            const owner = slot.owner orelse { self.stop(error.Retained); return error.Retained; };
            const info = owner.info() orelse continue;
            if (owner.state != .handed_off or owner.source.flags != 0 or
                !std.meta.eql(info.buffer, self.public_import.reference.buffer)) continue;
            // Drop only the fresh verification import. The original physical
            // owner retains its own reference and every page registration.
            self.public_import.close() catch |err| { self.stop(err); return err; };
            slot.public_users = try std.math.add(u64, slot.public_users, 1);
            return .{ .epoch = self.epoch, .serial = slot.serial, .slot = @intCast(index) };
        }
        return self.mapBuffer(.public_import, deadline) catch |err| {
            self.public_import.close() catch |cleanup| { self.stop(cleanup); return cleanup; };
            return err;
        };
    }
    const MappingSource = union(enum) { queue: struct { fence: r4os.abi.GfxFence, which: u32 }, initial_image, public_import };
    fn mapBuffer(self: *Owner, request: MappingSource, deadline: u64) !BufferHandle {
        const current = try self.now();
        if (self.graph_closing or self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.buffer_active != null or self.sequence.self_address != 0 or self.outputs.active()) return error.Busy;
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        const serial = try std.math.add(u64, self.buffer_serial, 1);
        const heap = self.ctx.?.heap() orelse return error.Api;
        const index = self.buffers.acquire(heap) catch |err| { if (err != error.Memory and err != error.Exhausted) self.stop(err); return err; };
        const memory = self.memory_api orelse return error.Api;
        const slot = &self.buffers.items()[index];
        slot.heap = heap;
        const result = heap.allocate(@sizeOf(BufferStorage), @alignOf(BufferStorage), &slot.allocation);
        const allocation = slot.allocation;
        if (result != r4os.abi.driver_heap_ok and allocation.handle == 0) return error.Memory;
        if (allocation.version != 1 or allocation.size < @sizeOf(r4os.abi.DriverHeapAllocation) or allocation.handle == 0 or
            allocation.cpu_address == 0 or allocation.cpu_address % @alignOf(BufferStorage) != 0 or allocation.reserved != 0 or
            allocation.byte_length < @sizeOf(BufferStorage) or allocation.alignment < @alignOf(BufferStorage) or
            allocation.cpu_address > std.math.maxInt(u64) - allocation.byte_length) {
            self.stop(error.Descriptor);
            return error.Descriptor;
        }
        errdefer {
            if (slot.pending_source.reference.id == 0 and slot.pending_source.buffer.id == 0) {
                if (heap.release(allocation.handle) == r4os.abi.driver_heap_ok) slot.* = .{} else self.stop(error.Retained);
            }
        }
        if (result != r4os.abi.driver_heap_ok) return error.Memory;
        const source = &slot.pending_source;
        const status = switch (request) {
            .queue => |job| blk: {
                const queue = (if (self.copy_backend) |backend| @as(?r4os.driver_queue.Context, backend.queue) else self.ctx.?.graphicsQueue()) orelse return error.Api;
                break :blk queue.retainResource(&job.fence, job.which, source);
            },
            .initial_image => blk: {
                const work = if (self.initial_image) |*value| value else return error.State;
                if (!self.preparedPresentation(work.presentation)) return error.State;
                break :blk memory.bufferImport(&work.presentation.surface.shadow.reference, source);
            },
            .public_import => blk: { source.* = try self.public_import.take(); break :blk r4os.abi.gfx_buffer_result_ok; },
        };
        if (status != r4os.abi.gfx_buffer_result_ok and source.reference.id == 0 and source.buffer.id == 0) return switch (status) {
            r4os.abi.gfx_buffer_error_oom => error.Memory,
            r4os.abi.gfx_buffer_error_busy => error.Busy,
            r4os.abi.gfx_buffer_error_stale, r4os.abi.gfx_buffer_error_closed => error.Stale,
            r4os.abi.gfx_buffer_error_unsupported, r4os.abi.err_no_fn, r4os.abi.err_no_group => error.Unsupported,
            else => error.Resource,
        };
        // Invalid returned ownership must remain inspectable; never drop an
        // unvalidated handle on an allocation error.
        if (source.version != 1 or source.size < @sizeOf(r4os.abi.GfxBufferReference) or source.reserved0 != 0 or
            source.reference.id == 0 or source.reference.generation == 0 or source.reference.reserved0 != 0 or
            source.buffer.id == 0 or source.buffer.generation == 0 or source.buffer.reserved0 != 0 or
            source.flags & ~@as(u32, r4os.abi.gfx_buffer_reference_mapping_only | r4os.abi.gfx_buffer_reference_immutable) != 0) {
            self.stop(error.Descriptor); return error.Descriptor;
        }
        errdefer {
            if (memory.bufferRelease(&source.reference) == r4os.abi.gfx_buffer_result_ok) source.* = .{} else self.stop(error.Retained);
        }
        if (status != r4os.abi.gfx_buffer_result_ok) return error.Resource;
        if (source.flags != @as(u32, if (request == .queue) r4os.abi.gfx_buffer_reference_mapping_only else 0)) return error.Unsupported;
        if (request == .initial_image and !std.meta.eql(source.buffer, self.initial_image.?.presentation.surface.shadow.buffer)) return error.Stale;
        var token = try self.channel.?.handoff(deadline);
        const storage: *BufferStorage = @ptrFromInt(allocation.cpu_address);
        storage.names = .{};
        const value = buffer_mapping.Owner.initResident(&token, &self.ctx.?, self.adapter_id, space, self.graph.?.reservation, source.*, deadline, &storage.names) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| {
                self.stop(restore);
                return restore;
            };
            return err;
        };
        const owner = &storage.owner;
        owner.* = value;
        slot.owner = owner;
        source.* = .{};
        slot.serial = serial;
        slot.cacheable = request == .queue;
        slot.public_users = if (request == .public_import) 1 else 0;
        slot.last_used = self.copy_completed +| 1;
        slot.last_used_ns = current;
        self.buffer_serial = serial;
        self.buffer_active = index;
        return .{ .epoch = self.epoch, .serial = serial, .slot = index };
    }
    fn findBuffer(self: *Owner, handle: BufferHandle) !*buffer_mapping.Owner {
        _ = try self.now();
        if (handle.epoch != self.epoch or handle.slot >= self.buffers.items().len or handle.serial == 0 or
            self.buffers.items()[handle.slot].serial != handle.serial) return error.Stale;
        return self.buffers.items()[handle.slot].owner orelse return error.Stale;
    }
    pub fn bufferStatus(self: *Owner, handle: BufferHandle) !BufferStatus {
        const owner = try self.findBuffer(handle);
        return .{ .state = owner.state, .info = owner.info(), .rejected = owner.rejected, .host_rejected = owner.host_rejected };
    }
    /// Make room for future canonical copy resources. No queued job is taken
    /// and no current copy/flip/cursor mapping may be touched. One idle cache
    /// entry starts real RM retirement per call; completion frees its slot.
    /// Unused mapping-only entries also expire after a short idle interval,
    /// so closing a producer does not require a future submission or shutdown
    /// to release its pinned backing. Active, public and scanout uses survive.
    pub fn prepareCopyMappings(self: *Owner, needed: usize, byte_limit: u64, deadline: u64) !bool {
        const current = try self.now();
        if (needed > std.math.maxInt(u32)) return error.Bounds;
        if (self.copyBusy() or self.hasQueuedWork() or self.cursor_point != null or self.cursor_reserving or self.graph_closing or self.buffer_active != null or
            self.fifo_active != null or self.virtuals.active_range != null or self.native_active != null or self.context_active != null or self.outputs.active() or self.sequence.self_address != 0 or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        var available: usize = 0;
        var cached_bytes: u64 = 0;
        var oldest: ?usize = null;
        var expired: ?usize = null;
        next: for (self.buffers.items(), 0..) |*slot, index| {
            if (slot.allocation.handle == 0) { available += 1; continue; }
            const owner = slot.owner orelse continue;
            if (!slot.cacheable or slot.evicting or slot.public_users != 0 or owner.state != .handed_off or owner.info() == null or
                owner.source.flags != r4os.abi.gfx_buffer_reference_mapping_only) continue;
            for (&self.presentation_slots) |*presentation_slot| if (presentation_slot.*) |*entry| {
                if (std.meta.eql(entry.surface.shadow.buffer, owner.source.buffer)) continue :next;
            };
            cached_bytes +|= owner.mapped_bytes;
            if (!owner.aliases.empty()) continue;
            if (oldest == null or slot.last_used < self.buffers.items()[oldest.?].last_used) oldest = index;
            if (current -| slot.last_used_ns >= copy_mapping_idle_ns and
                (expired == null or slot.last_used_ns < self.buffers.items()[expired.?].last_used_ns)) expired = index;
        }
        const pressure = available < needed or cached_bytes > byte_limit;
        const index = (if (pressure) oldest else expired) orelse return false;
        const slot = &self.buffers.items()[index];
        try self.retireBuffer(.{ .epoch = self.epoch, .serial = slot.serial, .slot = @intCast(index) }, deadline, true);
        slot.evicting = true;
        return true;
    }
    pub fn retireBuffer(self: *Owner, handle: BufferHandle, deadline: u64, quiesced: bool) !void {
        _ = try self.findBuffer(handle);
        if (self.buffers.items()[handle.slot].public_users != 0) return error.Busy;
        return self.retireBufferOwned(handle, deadline, quiesced);
    }
    /// Returns true only when the last reference starts physical retirement.
    /// A non-last close ends this caller's use without waiting for other VAs.
    pub fn releaseVirtualReference(self: *Owner, handle: BufferHandle, deadline: u64, quiesced: bool) !bool {
        _ = try self.findBuffer(handle);
        if (!quiesced) return error.Busy;
        const slot = &self.buffers.items()[handle.slot];
        if (slot.public_users == 0) return error.Stale;
        if (slot.public_users > 1) { slot.public_users -= 1; return false; }
        try self.retireBufferOwned(handle, deadline, true);
        slot.public_users = 0; // No new borrower may join a destroying owner.
        return true;
    }
    fn retireBufferOwned(self: *Owner, handle: BufferHandle, deadline: u64, quiesced: bool) !void {
        const owner = try self.findBuffer(handle);
        if (self.copyBusy() or self.hasQueuedWork()) return error.Busy;
        if (!quiesced or self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        if (owner.state != .handed_off) return error.State;
        var token = try self.channel.?.handoff(deadline);
        owner.beginDestroy(&token, deadline, quiesced) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| {
                self.stop(restore);
                return restore;
            };
            return err;
        };
        self.buffer_active = handle.slot;
    }
    /// Returns a runtime handle immediately; nativeBufferStatus publishes a
    /// borrowed driver reference only after RM allocation/map ACKs and common
    /// commit. Consumers import that reference through the common API.
    pub fn allocateNativeBuffer(self: *Owner, bytes: u64, deadline: u64) !BufferHandle {
        try self.admitNativeRmCreation();
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        return self.allocateNativePlan(try vram.surface.raw(self.adapter_id, space, bytes), deadline);
    }
    pub fn allocateNativeSurface(self: *Owner, request: vram.surface.Request, deadline: u64) !BufferHandle {
        try self.admitNativeRmCreation();
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        const caps = self.nativeMemoryCapabilities() orelse return error.State;
        return self.allocateNativePlan(try vram.surface.create(self.adapter_id, space, caps, request), deadline);
    }
    /// Own scanout requires a verified contiguous physical extent in the
    /// display DMA context, while retaining the common native BO descriptor.
    /// Admission uses the same clearing policy as actual allocation. A GPU
    /// without the global cleared-VIDMEM guarantee can use the exact GSP
    /// memset binding; this check alone neither allocates nor clears VRAM.
    pub fn validateDisplaySurface(self: *Owner, request: vram.surface.Request) !void {
        const space = (self.nativeAddressSpace() orelse return error.Busy).*;
        const caps = self.nativeMemoryCapabilities() orelse return error.Busy;
        const summary = self.nativeMemory() orelse return error.Busy;
        const plan = try vram.surface.create(self.adapter_id, space, caps, request);
        _ = try self.displaySurfacePolicy(space, caps, @min(summary.physical_bytes, summary.reported_bytes), plan);
    }
    pub fn allocateDisplaySurface(self: *Owner, request: vram.surface.Request, deadline: u64) !BufferHandle {
        try self.admitNativeRmCreation();
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        const caps = self.nativeMemoryCapabilities() orelse return error.State;
        const summary = self.nativeMemory() orelse return error.State;
        const plan = try vram.surface.create(self.adapter_id, space, caps, request);
        const policy = try self.displaySurfacePolicy(space, caps, @min(summary.physical_bytes, summary.reported_bytes), plan);
        return self.allocateNativePlanStorage(plan, policy, deadline);
    }
    fn displaySurfacePolicy(self: *const Owner, space: @import("gsp_vaspace.zig").Info, caps: @import("gsp_memory_caps.zig").Info,
        physical_bytes: u64, plan: vram.surface.Plan) !vram.storage.Policy
    {
        _ = try display_resources.image.create(plan, 1, 1);
        const policy: vram.storage.Policy = .{ .capabilities = caps, .physical_bytes = physical_bytes,
            .role = .scanout, .clear = self.memoryClearBinding() };
        try policy.validate(space, plan.allocation_bytes);
        return policy;
    }
    fn memoryClearBinding(self: *const Owner) ?@import("gsp_memory_clear.zig").Binding {
        const info = self.static_info orelse return null;
        return .{ .epoch = self.epoch, .client = info.client, .subdevice = info.subdevice };
    }
    /// Private instance/USERD/method backing must be initially cleared, by
    /// the advertised RM guarantee or an acknowledged explicit GSP memset.
    pub fn allocateNativeStorage(self: *Owner, bytes: u64, deadline: u64) !BufferHandle {
        return self.allocatePrivateStorage(bytes, 65536, false, false, deadline);
    }
    /// NVKMS only admits ISO cursor surfaces. Keep both private slots
    /// in the display-capable framebuffer heap, never NO_SCANOUT control FB.
    pub fn allocateCursorStorage(self: *Owner, deadline: u64) !BufferHandle {
        return self.allocatePrivateStorageRole(2 * cursor_image.max_bytes, 65536, false, false, .cursor, deadline);
    }
    pub fn allocateGraphicsContextStorage(self: *Owner, requirement: execution_context.wire.graphics.Requirement, deadline: u64) !BufferHandle {
        return self.allocatePrivateStorage(requirement.bytes, requirement.alignment, true, requirement.readonly, deadline);
    }
    fn allocatePrivateStorage(self: *Owner, bytes: u64, alignment: u64, privileged: bool, readonly: bool, deadline: u64) !BufferHandle {
        return self.allocatePrivateStorageRole(bytes, alignment, privileged, readonly, .control, deadline);
    }
    fn allocatePrivateStorageRole(self: *Owner, bytes: u64, alignment: u64, privileged: bool, readonly: bool,
        role: vram.storage.Role, deadline: u64) !BufferHandle
    {
        try self.admitNativeRmCreation();
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        const caps = self.nativeMemoryCapabilities() orelse return error.State;
        const memory_summary = self.nativeMemory() orelse return error.State;
        const policy: vram.storage.Policy = .{ .capabilities = caps, .physical_bytes = @min(memory_summary.physical_bytes, memory_summary.reported_bytes),
            .role = role, .clear = self.memoryClearBinding() };
        const plan = try vram.surface.rawPrivate(self.adapter_id, space, bytes, alignment, privileged, readonly);
        try policy.validate(space, plan.allocation_bytes);
        return self.allocateNativePlanStorage(plan, policy, deadline);
    }
    fn allocateNativePlan(self: *Owner, plan: vram.surface.Plan, deadline: u64) !BufferHandle {
        return self.allocateNativePlanStorage(plan, null, deadline);
    }
    fn allocateNativePlanStorage(self: *Owner, plan: vram.surface.Plan, policy: ?vram.storage.Policy, deadline: u64) !BufferHandle {
        return self.openNativeBuffer(plan, policy, deadline) catch |err| { self.hostRejection(.native_buffer, err); return err; };
    }
    fn openNativeBuffer(self: *Owner, plan: vram.surface.Plan, policy: ?vram.storage.Policy, deadline: u64) !BufferHandle {
        try self.admitNativeRmCreation();
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        try self.channel.?.guard(deadline);
        try self.memory_admission.admit(self, plan.allocation_bytes, policy != null);
        const serial = try std.math.add(u64, self.buffer_serial, 1);
        const heap = self.ctx.?.heap() orelse return error.Api;
        const index = self.native_buffers.acquire(heap) catch |err| { if (err != error.Memory and err != error.Exhausted) self.stop(err); return err; };
        const slot = &self.native_buffers.items()[index];
        slot.heap = heap;
        const result = heap.allocate(@sizeOf(NativeBufferStorage), @alignOf(NativeBufferStorage), &slot.allocation);
        const allocation = slot.allocation;
        if (result != r4os.abi.driver_heap_ok and allocation.handle == 0) return error.Memory;
        if (allocation.version != 1 or allocation.size < @sizeOf(r4os.abi.DriverHeapAllocation) or allocation.handle == 0 or
            allocation.cpu_address == 0 or allocation.cpu_address % @alignOf(NativeBufferStorage) != 0 or allocation.reserved != 0 or
            allocation.byte_length < @sizeOf(NativeBufferStorage) or allocation.alignment < @alignOf(NativeBufferStorage) or
            allocation.cpu_address > std.math.maxInt(u64) - allocation.byte_length) {
            self.stop(error.Descriptor); return error.Descriptor;
        }
        errdefer if (heap.release(allocation.handle) == r4os.abi.driver_heap_ok) { slot.* = .{}; } else self.stop(error.Retained);
        if (result != r4os.abi.driver_heap_ok) return error.Memory;
        var token = try self.channel.?.handoff(deadline);
        const storage: *NativeBufferStorage = @ptrFromInt(allocation.cpu_address);
        storage.names = .{};
        const value = vram.Owner.initResident(&token, &self.ctx.?, self.adapter_id, space, self.graph.?.reservation, plan, policy, deadline, &storage.names) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; };
            return err;
        };
        const owner = &storage.owner;
        owner.* = value; slot.owner = owner; slot.serial = serial;
        // Head and cursor images use the same host-owned ISO framebuffer regions as
        // application images. Only private RM control storage stays in GSP's
        // reserved heap; its apparent free capacity cannot fund scanout.
        if (space.host != null and (if (policy) |backing_policy| backing_policy.needsIso() else true))
            owner.user_memory = .{ .heap = &self.user_vram, .view = &self.memory_inventory };
        self.buffer_serial = serial; self.native_active = index;
        return .{ .epoch = self.epoch, .serial = serial, .slot = index };
    }
    // Address-space lookup intentionally hides a currently loaned RM channel.
    // Check transient ownership first for memory, contexts and channels, so
    // ordinary reclamation or power RPCs retry without poisoning the device.
    fn admitNativeRmCreation(self: *Owner) !void {
        _ = try self.now();
        if (self.power_active or self.powerStopping()) return error.Busy;
        if (self.graph_closing or self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.buffer_active != null or self.sequence.self_address != 0 or self.outputs.active()) return error.Busy;
        if (self.display_upload_job != null or self.display_work != null or self.cursor_point != null or self.cursor_upload != null or
            self.audio_work != null or self.monitor_work != null or self.sor_work != null) return error.Busy;
        const channel = if (self.channel) |*value| value else return error.State;
        if (self.activeChannel() != channel or channel.phase != .idle or channel.pending != null or channel.in_lockdown) return error.Busy;
    }
    fn findNativeBuffer(self: *Owner, handle: BufferHandle) !*vram.Owner {
        _ = try self.now();
        if (handle.epoch != self.epoch or handle.slot >= self.native_buffers.items().len or handle.serial == 0 or
            self.native_buffers.items()[handle.slot].serial != handle.serial) return error.Stale;
        return self.native_buffers.items()[handle.slot].owner orelse return error.Stale;
    }
    pub fn nativeBufferStatus(self: *Owner, handle: BufferHandle) !NativeBufferStatus {
        const owner = try self.findNativeBuffer(handle);
        return .{ .state = owner.state, .info = owner.info(), .rejected = owner.rejected, .host_rejected = owner.host_rejected };
    }
    pub fn retainNativeStorage(self: *Owner, handle: BufferHandle, use: *vram.storage.Use) !void {
        if (self.graph_closing) return error.Busy;
        try (try self.findNativeBuffer(handle)).retainStorage(use);
    }
    pub fn releaseNativeBuffer(self: *Owner, handle: BufferHandle) !void {
        const owner = try self.findNativeBuffer(handle);
        try owner.closeReference();
        if (!owner.common_live and !owner.namespace_live) try self.freeNativeSlot(handle.slot);
    }
    fn freeNativeSlot(self: *Owner, index: usize) !void {
        const slot = &self.native_buffers.items()[index];
        const heap = slot.heap orelse return error.Api;
        if (heap.release(slot.allocation.handle) != r4os.abi.driver_heap_ok) return error.Retained;
        slot.* = .{};
    }
    fn collectNativeBuffer(self: *Owner, deadline: u64) !bool {
        if (self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return false;
        const memory = blk: {
            for (self.native_buffers.items()) |*slot| if (slot.owner) |owner| { if (owner.closing and owner.common_live) break :blk owner.memory; };
            return false;
        };
        var ticket: r4os.abi.GfxOwnedBufferRelease = .{};
        const result = memory.bufferTakeRelease(self.adapter_id, self.epoch, &ticket);
        if (result == r4os.abi.gfx_buffer_error_busy) return false;
        if (result != r4os.abi.gfx_buffer_result_ok) return error.Retained;
        for (self.native_buffers.items(), 0..) |*slot, index| if (slot.owner) |owner| {
            if (!owner.accepts(ticket)) continue;
            var token = try self.channel.?.handoff(deadline);
            try owner.beginDestroy(&token, ticket, deadline);
            self.native_active = @intCast(index); return true;
        };
        return error.Descriptor; // Claimed unknown identity remains held.
    }
    fn admitVirtual(self: *Owner, deadline: u64, closing: bool) !void {
        _ = try self.now();
        if (self.graph_closing and !closing) return error.Busy;
        if (self.power_active or self.powerStopping() and !closing or self.copyBusy() or self.hasQueuedWork() or
            self.cursor_point != null or self.cursor_reserving or self.display_work != null or self.hasDisplayFlips() or
            self.sequence.self_address != 0 or self.outputs.active() or self.virtuals.active_range != null or
            self.channel == null or self.activeChannel() != &self.channel.? or self.graph == null or self.graph.?.state != .loaned or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        try self.virtuals.configure(&self.ctx.?, self.epoch);
    }
    fn returnVirtualLoan(self: *Owner, token: *boot.Handoff, deadline: u64) !void {
        if (token.claimed) { self.stop(error.Retained); return error.Retained; }
        self.channel = exchange.Exchange.init(token, deadline) catch |err| { self.stop(err); return err; };
    }
    /// Internal worker handles only. The common broker must authenticate any
    /// future application request before calling these operations.
    pub fn allocateVirtualRange(self: *Owner, config: virtual_resources.range.Config, deadline: u64) !VirtualHandle {
        try self.admitVirtual(deadline, false);
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        var token = try self.channel.?.handoff(deadline);
        return self.virtuals.create(&token, space, self.graph.?.reservation, config, deadline) catch |err| {
            try self.returnVirtualLoan(&token, deadline);
            if (self.virtuals.failure != null) self.stop(err);
            return err;
        };
    }
    pub fn virtualStatus(self: *Owner, handle: VirtualHandle) !VirtualStatus {
        _ = try self.now();
        const entry = try self.virtuals.find(handle);
        const value = if (entry.value) |*owner| owner else return error.State;
        return .{ .state = value.state, .info = value.info(), .rejected = value.rejected };
    }
    pub fn virtualBindingStatus(self: *Owner, handle: VirtualBindingHandle) !VirtualBindingStatus {
        _ = try self.now();
        const value = &(try self.virtuals.findBinding(handle)).value;
        return .{ .mapped = value.mapped, .bytes = if (value.mapping) |mapping| mapping.bytes else 0, .rejected = value.rejected };
    }
    /// RAM may cross several existing RM registrations. Returns one bounded
    /// chunk; the caller advances both offsets by bytes for the next request.
    pub fn mapVirtualBuffer(self: *Owner, handle: VirtualHandle, source: VirtualSource, memory_offset: u64,
        virtual_offset: u64, bytes: u64, deadline: u64) !struct { handle: VirtualBindingHandle, bytes: u64 }
    {
        try self.admitVirtual(deadline, false);
        const binding = self.virtuals.prepareBinding(handle) catch |err| {
            if (self.virtuals.failure != null) self.stop(err);
            return err;
        };
        errdefer self.virtuals.discardBinding(binding) catch |err| self.stop(err);
        const use = &(try self.virtuals.findBinding(binding)).value.source;
        switch (source) {
            .system => |buffer| try (try self.findBuffer(buffer)).retainAliasChunk(use, memory_offset, bytes),
            .native => |buffer| try (try self.findNativeBuffer(buffer)).retainAlias(use, memory_offset, bytes),
            .native_reference => |reference| {
                const owner = for (self.native_buffers.items()) |*slot| {
                    const candidate = slot.owner orelse continue;
                    if (std.meta.eql(candidate.reservation.buffer, reference.buffer)) break candidate;
                } else return error.Stale;
                try owner.retainAliasReference(use, reference, memory_offset, bytes);
            },
        }
        const retained = try use.info();
        var token = try self.channel.?.handoff(deadline);
        self.virtuals.beginMap(&token, binding, virtual_offset, deadline) catch |err| {
            try self.returnVirtualLoan(&token, deadline);
            return err;
        };
        return .{ .handle = binding, .bytes = retained.bytes };
    }
    pub fn unmapVirtualBuffer(self: *Owner, handle: VirtualBindingHandle, deadline: u64, quiesced: bool) !void {
        if (!quiesced) return error.Busy;
        try self.admitVirtual(deadline, true);
        var token = try self.channel.?.handoff(deadline);
        self.virtuals.beginUnmap(&token, handle, deadline, true) catch |err| {
            try self.returnVirtualLoan(&token, deadline); return err;
        };
    }
    pub fn discardVirtualBinding(self: *Owner, handle: VirtualBindingHandle) !void {
        _ = try self.now();
        self.virtuals.discardBinding(handle) catch |err| {
            if (self.virtuals.failure != null) self.stop(err);
            return err;
        };
    }
    pub fn retireVirtualRange(self: *Owner, handle: VirtualHandle, deadline: u64, quiesced: bool) !void {
        if (!quiesced) return error.Busy;
        try self.admitVirtual(deadline, true);
        const entry = try self.virtuals.find(handle);
        if (entry.value != null and entry.value.?.state == .finished) {
            self.virtuals.discardRejected(handle) catch |err| {
                if (self.virtuals.failure != null) self.stop(err);
                return err;
            };
            return;
        }
        var token = try self.channel.?.handoff(deadline);
        self.virtuals.beginDestroy(&token, handle, deadline, true) catch |err| {
            try self.returnVirtualLoan(&token, deadline); return err;
        };
    }
    /// Requires all engine users independently quiesced. Each child mapping
    /// is drained before graph.beginDestroy may send any parent/event free.
    pub fn beginDestroyGraph(self: *Owner, deadline: u64, quiesced: bool) !void {
        const current = try self.now();
        if (self.copy_backend) |backend| if (backend.channel != null) return error.Busy;
        if (self.copyBusy() or self.hasQueuedWork() or self.display_engine_owner != null or self.mode_control_owner != null) return error.Busy;
        if (!quiesced or self.graph_closing or self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or self.buffer_active != null or self.outputs.active() or
            self.sequence.self_address != 0 or self.nativeObject() == null or self.channel.?.phase != .idle) return error.Busy;
        try self.channel.?.guard(deadline);
        if (self.power_owner) |*owner| {
            const ready = if (self.shutdown_closing) try owner.stopForFirmwareUnload(current) else try owner.stop(current);
            if (!ready) return error.Busy;
        }
        for (self.native_buffers.items(), 0..) |*slot, index| if (slot.owner != null) {
            try self.releaseNativeBuffer(.{ .epoch = self.epoch, .serial = slot.serial, .slot = @intCast(index) });
        };
        self.graph_closing = true;
        if (self.power_owner) |*owner| if (!owner.closed())
            self.log("NVIDIA power: terminal-page=retained lifetime=firmware-unload detach-rejected={?x} poll-mask={x} release=after-confirmed-reset",
                .{owner.detach_rejection, owner.active_mask});
        self.virtual_provider.close();
        self.close_deadline = deadline;
    }
    pub fn takeDisplayChanges(self: *Owner) !subscriptions.Changes {
        const current = try self.now();
        const graph = if (self.graph) |*value| value else return error.State;
        if (self.graph_closing or graph.state != .loaned) return error.State;
        // Coalesced metadata is independent of who currently owns the RM
        // exchange. The subscription owner still rejects a pending receipt.
        return graph.takeChanges(try std.math.add(u64, current, std.time.ns_per_s));
    }
    // DriverWork runs on the shared 64 KB task stack. Keep independently
    // selected phase buffers in their own frames; inlining all branches here
    // reserves their combined high-water mark even during the first RM poll.
    // Preserve the existing non-inlined dispatcher and its exact error.
    inline fn phaseCall(comptime Result: type, comptime function: anytype, args: anytype) anyerror!Result {
        return @call(.never_inline, function, args);
    }
    noinline fn advance(self: *Owner) !Progress {
        const current = try self.now();
        if (self.graph) |*graph| if (graph.address_space) |*space| {
            if (try space.host_storage.collectDeferred()) return .progress;
        };
        // A system mapping may have finished its own unmap while another
        // native BO still needs this worker's RM channel. Retry only the
        // common collection barrier, without keeping that channel borrowed.
        if (try self.collectDeferredBuffer()) return .progress;
        if (try self.collectDeferredChannel()) return .progress;
        if (self.unload.self_address == 0 and !self.shutdown_closing) {
            self.observePower(current);
            self.observeAdaptiveRefresh(current);
        }
        const channel = self.activeChannel() orelse return error.State;
        self.snapshot.polls +|= 1;
        self.snapshot.last_poll_ns = current;
        if (self.sequence.self_address != 0) {
            switch (try self.sequence.step()) {
                .wait_until => return .idle,
                .advanced => {},
                .complete => {
                    if (!self.sequence.close()) return error.Retained;
                    self.snapshot.sequencers +|= 1;
                    self.snapshot.events +|= 1;
                    self.snapshot.last_event_ns = current;
                },
            }
            return .progress;
        }
        if (self.unload.self_address != 0) return phaseCall(Progress, advanceUnload, .{ self, current });
        if (self.power_active) return phaseCall(Progress, advancePowerOwner, .{ self, current });
        if (self.display_channel_active) |index| return phaseCall(Progress, advanceDisplayChannelOwner, .{ self, current, index });
        if (self.mode_control_active) return phaseCall(Progress, advanceModeControlOwner, .{ self, current });
        if (self.display_engine_active) return phaseCall(Progress, advanceDisplayEngineOwner, .{ self, current });
        if (self.fifo_active) |index| return phaseCall(Progress, advanceFifoOwner, .{ self, current, index });
        if (self.context_active) |index| return phaseCall(Progress, advanceContextOwner, .{ self, current, index });
        if (self.virtuals.active()) |owner| {
            if (owner.state == .ready or owner.state == .closed) {
                if (owner.state == .ready) try self.rejection(.mapping, owner.plan.object, owner.rejected, null);
                const deadline = owner.deadline;
                var token = try owner.handoff(deadline);
                self.channel = try exchange.Exchange.init(&token, deadline);
                _ = try self.virtuals.complete();
                return .progress;
            }
            if (@call(.never_inline, @TypeOf(owner.*).poll, .{owner}) catch |err| { self.rmFailure(.mapping, owner.plan.object, owner.rejected); return err; }) |dispatch| {
                try self.notification(&owner.exchange, dispatch, current);
                return .progress;
            }
            return if (owner.exchange.phase == .waiting) .idle else .progress;
        }
        if (self.native_active) |index| return phaseCall(Progress, advanceNativeBufferOwner, .{ self, current, index });
        if (self.buffer_active) |index| return phaseCall(Progress, advanceBufferOwner, .{ self, current, index });
        // The display transaction owns these setter replies. Do not let the
        // generic graph/query dispatcher consume or acknowledge them.
        if (self.display_work) |*work| if (work.refresh) |*refresh| {
            if (refresh.control.phase != .core) return phaseCall(Progress, advanceAdaptiveControl, .{ self, current });
        };
        if (self.display_work) |*work| if (work.wake_before_link and work.wake_receipt == 0) {
            if (self.monitor_work != null) return phaseCall(Progress, advanceMonitorPower, .{ self, current });
            return phaseCall(Progress, advanceDigitalWake, .{ self, current });
        };
        if (self.display_work) |*work| if (work.linkControl()) |link| {
            if (work.link_restore != null or link.phase == .before_scanout or link.phase == .after_scanout or
                (link.mst_rebuild != null and link.phase == .scanout)) return phaseCall(Progress, advanceDisplayLink, .{ self, current });
        };
        if (self.audio_work != null) return phaseCall(Progress, advanceDisplayAudio, .{ self, current });
        if (self.monitor_work != null) return phaseCall(Progress, advanceMonitorPower, .{ self, current });
        if (self.sor_work != null) return phaseCall(Progress, advanceSorAssignment, .{ self, current });
        // Drain an already observable GSP fault before publishing CE success.
        // Active RPC owners above already receive before sending their work.
        if ((self.copyBusy() or self.cursor_point != null) and channel.phase == .idle) {
            const end = channel.deadline orelse try std.math.add(u64, current, std.time.ns_per_s);
            if (try channel.poll(end)) |dispatch| {
                try self.notification(channel, dispatch, current); return .progress;
            }
        }
        if (try @call(.never_inline, @TypeOf(self.native_copy.probe).step, .{ &self.native_copy.probe, self, current })) return .progress;
        if (try phaseCall(bool, advanceCursorUpload, .{ self, current })) return .progress;
        if (try phaseCall(bool, advanceGraphicsUpload, .{ self, current })) return .progress;
        if (try phaseCall(bool, advanceDisplayUpload, .{ self, current })) return .progress;
        if (try phaseCall(bool, advanceInitialImage, .{ self, current })) return .progress;
        if (try phaseCall(bool, advanceDisplay, .{ self, current })) return .progress;
        if (try phaseCall(bool, advanceDisplayFlip, .{ self, current })) return .progress;
        if (try phaseCall(bool, advanceCursorPoint, .{ self, current })) return .progress;
        if (try phaseCall(bool, advanceCopy, .{ self, current })) return .progress;
        if (try phaseCall(bool, advanceGraphics, .{ self, current })) return .progress;
        if (try phaseCall(bool, advancePushBatch, .{ self, current })) return .progress;
        if (self.queued_native) |queued| {
            if (queued.phase == .done) { try self.releaseWork(); return .progress; }
            if (try phaseCall(bool, @TypeOf(queued.*).step, .{ queued, self, current })) return .progress;
        }
        if (self.queued_render) |queued| {
            if (queued.phase == .done) { try self.releaseWork(); return .progress; }
            if (try phaseCall(bool, @TypeOf(queued.*).step, .{ queued, self, current })) return .progress;
        }
        if (try phaseCall(bool, advancePresentFrame, .{ self, current })) return .progress;
        if (try phaseCall(bool, advanceDirect, .{ self, current })) return .progress;
        // A due receiver batch gets the idle RM channel before another
        // queued frame. A continuously repainting desktop must not starve HPD.
        if (!self.shutdown_closing and self.outputs.state != .detached and try self.beginReceiverRefresh(current)) return .progress;
        if (try self.beginPower(current)) return .progress;
        if (!self.shutdown_closing) if (self.copy_backend) |backend| copy_admission: {
            if (self.copyAdmissionBusy()) break :copy_admission;
            const handle = if (self.presentation) |entry| blk: {
                if (!entry.pending or (!self.display_paused and !self.presentationValid())) break :copy_admission;
                break :blk entry.channel_handle;
            } else blk: {
                if (!backend.pending) break :copy_admission;
                break :blk backend.channel orelse break :copy_admission;
            };
            const copy_deadline = try std.math.add(u64, current, 3 * std.time.ns_per_s);
            if (!self.copyBusy() and self.cursor_point == null and self.buffer_active == null) {
                // Keep room for the next source/target and bound idle mapping
                // retention independently of the number of occupied slots.
                if (self.prepareCopyMappings(2, 128 * 1024 * 1024, copy_deadline) catch |err| blk: {
                    if (err == error.Busy) break :blk false; return err;
                }) return .progress;
            }
            const taken: ?bool = phaseCall(bool, beginCopyWork, .{ self, handle, backend.binding, copy_deadline }) catch |err| blk: {
                if (err == error.Busy) break :blk null; return err;
            };
            if (taken) |claimed| {
                if (claimed) return .progress;
                self.copy_backend.?.pending = self.hasDeferredPresentations();
                if (self.presentation) |entry| entry.pending = self.copy_backend.?.pending;
            }
            // A pending frame must not starve an output query or other
            // runtime owner that currently prevents taking the queue job.
        };
        // A physical slice completion returned through the outer device loop,
        // giving cursor/output owners one admission opportunity. Retained jobs
        // now resume by producer turn even when no new queue wake is pending.
        if (!self.copyAdmissionBusy() and self.cursor_point == null and self.fifo_active == null and
            self.context_active == null and self.virtuals.active_range == null and self.native_active == null and self.buffer_active == null and
            !self.display_engine_active and self.display_channel_active == null and !self.outputs.active() and
            self.sequence.self_address == 0 and self.channel.?.phase == .idle and self.channel.?.pending == null and
            self.channel.?.in_lockdown == false and try self.activateWork()) return .progress;
        if (self.nativeObject() != null and try self.collectNativeBuffer(if (self.graph_closing) self.close_deadline else try std.math.add(u64, current, 5 * std.time.ns_per_s))) return .progress;
        // Admission above handles pressure. Once the queue is empty, let
        // idle mappings retire through the same confirmed RM unmap path.
        // Native BO retirement must run first: system mapping cleanup also
        // invokes the common collector and cannot drive native RM work.
        if (!self.shutdown_closing and !self.graph_closing and !self.powerStopping()) if (self.copy_backend) |backend| {
            if (!backend.pending and (self.prepareCopyMappings(0, std.math.maxInt(u64),
                try std.math.add(u64, current, 3 * std.time.ns_per_s)) catch |err| blk: {
                if (err == error.Busy) break :blk false; return err;
            })) return .progress;
        };
        if (self.graph_closing and self.graph.?.state == .loaned) graph_close: {
            try channel.guard(self.close_deadline);
            // The common broker owns retirement order and its outstanding
            // claims. Do not remove its runtime handles behind the adapter.
            if (!self.virtual_provider.closed()) break :graph_close;
            if (self.native_queues.count != 0 or self.native_queues.spare.handle != 0) break :graph_close;
            for (&self.fifos, 0..) |*slot, index| if (slot.owner != null) {
                try self.retireExecutionChannel(.{ .epoch = self.epoch, .serial = slot.serial, .slot = @intCast(index) }, self.close_deadline, true);
                return .progress;
            };
            for (&self.contexts, 0..) |*slot, index| if (slot.owner) |owner| {
                if (!owner.held()) {
                    try self.retireExecutionContext(.{ .epoch = self.epoch, .serial = slot.serial, .slot = @intCast(index) }, self.close_deadline);
                    return .progress;
                }
            };
            for (&self.contexts) |*slot| if (slot.owner != null) break :graph_close;
            if (!self.graphics_cache.close(true)) return error.Retained;
            // Closing the cache can release the last native BO references
            // after this turn's earlier collection pass. Drain those RM
            // owners before a system mapping waits on common collection.
            if (try self.collectNativeBuffer(self.close_deadline)) return .progress;
            if (try self.virtuals.first()) |handle| {
                if (try self.virtuals.firstBinding(handle)) |binding| {
                    if ((try self.virtualBindingStatus(binding)).mapped) try self.unmapVirtualBuffer(binding, self.close_deadline, true)
                    else try self.discardVirtualBinding(binding);
                } else try self.retireVirtualRange(handle, self.close_deadline, true);
                return .progress;
            }
            for (self.buffers.items(), 0..) |*slot, index| if (slot.owner) |owner| {
                if (owner.state == .finished) continue;
                try self.retireBuffer(.{ .epoch = self.epoch, .serial = slot.serial, .slot = @intCast(index) }, self.close_deadline, true);
                return .progress;
            };
            for (self.buffers.items()) |*slot| if (slot.owner != null) break :graph_close;
            for (self.native_buffers.items()) |*slot| if (slot.owner != null) break :graph_close;
            try self.buffers.closeEmpty();
            try self.native_buffers.closeEmpty();
            if (!self.user_vram.empty()) return error.Retained;
            var token = try channel.handoff(self.close_deadline);
            try self.graph.?.reclaim(&token, self.close_deadline);
            try self.graph.?.beginDestroy(self.close_deadline);
            return .progress;
        }
        if (self.outputs.active()) {
            if (self.outputs.state == .complete or self.outputs.state == .obsolete) {
                var loan = try self.graph.?.loan(self.outputs.deadline);
                self.channel = try exchange.Exchange.init(&loan.runtime, self.outputs.deadline);
                try self.outputs.returned(current);
                try self.receiver_events.finished(self.epoch, current, hotplug.retrySnapshot(&self.outputs.data));
                self.log("NVIDIA gsp-outputs: generation={d} inventory={s} routes={d} receivers={d} native-output=unavailable",
                    .{self.output_generation, if (!self.outputs.data.coherent) @as([]const u8, "obsolete") else if (self.outputs.data.topology.rejected != null) "query-rejected" else "complete",
                        self.outputs.data.topology.count, self.outputs.data.count});
                if (self.outputs.data.final_rejection orelse self.outputs.data.topology.rejected) |rejected|
                    self.log("NVIDIA gsp-outputs: rejected command={x} rpc={?} rm={?}", .{@intFromEnum(rejected.command), rejected.rpc, rejected.control});
                if (self.outputs.data.coherent) {
                    if (self.output_generation == 1) if (self.outputs.board) |board| if (board.gpio_table) |*gpio| {
                        for (&gpio.hpd) |*hpd| if (hpd.entry_index) |index| if (index < gpio.count) {
                            const entry = gpio.entry(index) catch continue;
                            self.log("NVIDIA HPD-entry: function={d} index={d} raw={x} extra={?x} extension={?x} line={d} off={d} on={d} lock-pin={?} dedicated={} reserved={x} source=retained-VBIOS level=unread",
                                .{hpd.function,index,entry.raw,entry.extra,entry.extension_byte,entry.line,entry.off,entry.on,
                                    entry.lock_pin,entry.dedicated_lock,entry.reserved_bits});
                        };
                    };
                    const catalog = &self.outputs.data.topology;
                    self.log("NVIDIA gsp-heads: generation={d} count={?} observation=queried lease=no", .{self.output_generation, catalog.head_count});
                    for (catalog.routes[0..catalog.count]) |*route| {
                        self.log("NVIDIA gsp-route: display={x} active-heads={?} or={?} dcb-slot={?} ddc-port={?} communication-port={?}",
                            .{route.id, catalog.activeHeads(route.id), if (route.resource) |resource| resource.index else null,
                                if (route.resource) |resource| resource.dcb_index else null, if (route.buses) |buses| buses.ddc else null,
                                if (route.buses) |buses| buses.communication else null});
                        const wire = &route.wiring;
                        self.log("NVIDIA gsp-wire: display={x} relation={s} physical={s} rm-connector={?} heads={s} encoder={s} protocol={s}",
                            .{route.id, @tagName(wire.relation), @tagName(wire.physical_status),
                                if (wire.physical) |physical| @as(?u32, physical.index) else null,
                                @tagName(wire.heads), @tagName(wire.encoder), @tagName(wire.protocol)});
                        if (wire.relation == .static) {
                            const port = &wire.relation.static;
                            self.log("NVIDIA gsp-bus: display={x} dcb={d} connector={d} ccb={d} pmgr-i2c={?} pmgr-aux={?} assignment={s} mask={x} links={?}",
                                .{route.id, port.index, port.connector, port.ccb, port.i2c, port.aux, @tagName(port.assignment), port.output_mask, port.link_mask});
                            for (&wire.hpd) |*signal| if (signal.*) |hpd|
                                self.log("NVIDIA gsp-hpd: display={x} function={d} status={s} pin={?} active-high={?} level=unread",
                                    .{route.id, hpd.function, @tagName(hpd.status), hpd.line, hpd.active_high});
                            for (&wire.external_dongle, 0..) |*signal, bit| if (signal.*) |dongle|
                                self.log("NVIDIA gsp-xpio: display={x} dp-dvi={d} status={s} table={?} pin={?} level=unread",
                                    .{route.id, bit, @tagName(dongle.status), dongle.table, dongle.line});
                        } else if (wire.relation == .dynamic)
                            self.log("NVIDIA gsp-root: display={x} root={x} physical=not-inferred", .{route.id, wire.relation.dynamic});
                    }
                }
                return .progress;
            }
            const before = self.outputs.data.count;
            if (try self.outputs.poll()) |dispatch| {
                const source = self.outputs.channel() orelse return error.State;
                try self.notification(&source.exchange, try source.exchange.borrow(dispatch.ticket), current);
                return .progress;
            }
            if (self.outputs.data.count != before) {
                const capture = &self.outputs.data.receivers[before];
                self.log("NVIDIA gsp-receiver: candidate generation={d} display={x} status={s} edid={d} modes={d} audio={d} warnings={x} rpc={?} rm={?} source={s}",
                    .{self.output_generation, capture.display_id, @tagName(capture.status), capture.edid_bytes,
                        capture.report.mode_count, capture.report.audio_count, capture.report.warnings, capture.rpc_status, capture.control_status, @tagName(capture.source)});
                if (capture.buses != null or capture.ddc_rpc_status != null or capture.ddc_control_status != null)
                    self.log("NVIDIA gsp-ddc: generation={d} display={x} port={?} flags={?} retries={d} rpc={?} rm={?}",
                        .{self.output_generation, capture.display_id, if (capture.buses) |buses| @as(?u32, buses.ddc) else null,
                            capture.port_info, capture.ddc_retries, capture.ddc_rpc_status, capture.ddc_control_status});
                self.logReceiverReplies(self.output_generation, capture);
                if (capture.source == .aux or capture.aux_rpc_status != null or capture.aux_control_status != null or capture.aux_reply != null)
                    self.log("NVIDIA gsp-aux: generation={d} display={x} dpcd={d} retries={d} rpc={?} rm={?} reply={?}",
                        .{self.output_generation, capture.display_id, capture.aux_caps_bytes, capture.aux_retries,
                            capture.aux_rpc_status, capture.aux_control_status,
                            if (capture.aux_reply) |reply| @as(?u32, @intFromEnum(reply)) else null});
            }
            if (self.outputs.waiting()) return .idle;
            return if ((self.activeChannel() orelse return error.State).phase == .waiting) .idle else .progress;
        }
        return self.advanceStartup(current, channel);
    }
    fn logReceiverReplies(self: *Owner, catalog_generation: u64, capture: *const @import("gsp_receiver.zig").Capture) void {
        for ([_]?@import("gsp_receiver.zig").ReplyObservation{capture.last_reply, capture.last_rejection}, 0..) |value, index|
            if (value) |reply| self.log("NVIDIA gsp-receiver-reply: generation={d} display={x} kind={s} phase={s} command={x} block={?} receipt={d} ack={} rpc={?x} rm={?x}",
                .{catalog_generation, capture.display_id, if (index == 0) @as([]const u8, "last") else "last-rejection",
                    @tagName(reply.phase), @intFromEnum(reply.command), reply.block, reply.receipt_serial,
                    reply.acknowledged, reply.rpc, reply.control});
    }
    noinline fn advancePowerOwner(self: *Owner, current: u64) !Progress {
        const owner = if (self.power_owner) |*value| value else return error.State;
        if (owner.completed) {
            const deadline = owner.deadline;
            const operation = owner.operation orelse return error.State;
            const boost = switch (operation) { .boost => |value| value, else => null };
            self.log("NVIDIA power: control={x} status={?x} telemetry={s} poll-mask={x} policy={s} requested-level={?d} seconds={?d} accepted-level={d}",
                .{power.wire.command(operation),owner.last_status,@tagName(owner.status),owner.active_mask,
                @tagName(owner.performance.reason),if (boost) |value| @as(?u2, value.level) else null,
                if (boost) |value| @as(?u16, value.seconds) else null,owner.performance.accepted_level});
            var token = try owner.handoff(deadline);
            self.channel = try exchange.Exchange.init(&token, deadline);
            self.power_active = false;
            return .progress;
        }
        if (try @call(.never_inline, @TypeOf(owner.*).poll, .{ owner, current })) |dispatch| {
            try self.notification(&owner.active.?, dispatch, current);
            return .progress;
        }
        return if (owner.active.?.phase == .waiting) .idle else .progress;
    }
    noinline fn advanceDisplayChannelOwner(self: *Owner, current: u64, index: anytype) !Progress {
        const owner = if (self.display_channels[index]) |*value| value else return error.State;
        if (owner.state == .ready or owner.state == .closed) {
            if (owner.state == .ready) try self.rejection(.display_channel, owner.config.handle, owner.rejected, owner.host_rejected);
            if (owner.info()) |value| self.log("NVIDIA gsp-display-channel: handle={x} class={x} index={d} physical={x} bytes={d} methods=empty",
                .{value.config.handle,display_channel.wire.classFor(value.config.root,value.config.kind),value.config.index,value.config.physical,@as(u32, if (value.config.kind == .cursor) 0 else 4096)});
            const deadline = owner.deadline; var token = try owner.handoff(); const finished = owner.state == .finished;
            self.channel = try exchange.Exchange.init(&token, deadline);
            if (finished) self.display_channels[index] = null;
            self.display_channel_active = null; return .progress;
        }
        if (owner.retirementPending()) {
            // Already queued faults/events take priority over physical
            // retirement, just as they do over CE completion.
            if (owner.exchange.poll(owner.deadline) catch |err| { owner.quarantine(err); return err; }) |dispatch| { try self.notification(&owner.exchange, dispatch, current); return .progress; }
            self.device.?.observeDisplayRetirement(owner, owner.deadline) catch |err| { owner.quarantine(err); return err; };
            if (!owner.hardware_retired) return .idle;
        }
        if (@call(.never_inline, @TypeOf(owner.*).poll, .{owner}) catch |err| { self.rmFailure(.display_channel, owner.config.handle, owner.last_status); return err; }) |dispatch| {
            try self.notification(&owner.exchange, dispatch, current); return .progress;
        }
        return if (owner.exchange.phase == .waiting) .idle else .progress;
    }
    noinline fn advanceModeControlOwner(self: *Owner, current: u64) !Progress {
        const owner = if (self.mode_control_owner) |*value| value else return error.State;
        if (owner.state == .ready or owner.state == .closed) {
            if (owner.state == .ready) {
                try self.rejection(.display_engine, owner.binding.control, owner.rejected, null);
                if (!owner.obsolete) try self.validateModeQuery(self.mode_control_root.?, owner.mode);
            }
            if (owner.info()) |value| self.log("NVIDIA gsp-mode-query: handle={x} possible={} over-clock={} source-hz={d} bandwidth-kbps={d} floor-kbps={d} receipt={d} reservation=no",
                .{owner.binding.control,value.possible,value.over_clock,value.source_clock_hz,value.min_bandwidth_kbps,value.floor_bandwidth_kbps,value.receipt});
            const deadline = owner.deadline; var token = try owner.handoff();
            const finished = owner.state == .finished;
            self.channel = try exchange.Exchange.init(&token, deadline);
            if (finished) { self.mode_control_owner = null; self.mode_control_root = null; }
            self.mode_control_active = false; return .progress;
        }
        if (@call(.never_inline, mode_control.Owner.poll, .{owner}) catch |err| { self.rmFailure(.display_engine, owner.binding.control, owner.last_status); return err; }) |dispatch| {
            try self.notification(&owner.exchange, dispatch, current); return .progress;
        }
        return if (owner.exchange.phase == .waiting) .idle else .progress;
    }
    noinline fn advanceDisplayEngineOwner(self: *Owner, current: u64) !Progress {
        const owner = if (self.display_engine_owner) |*value| value else return error.State;
        if (owner.state == .ready or owner.state == .closed) {
            if (owner.state == .ready) try self.rejection(.display_engine, owner.binding.root, owner.rejected, null);
            if (owner.info()) |value| self.log("NVIDIA gsp-display-engine: root={x} class=c670 heads={d} windows={x} channels={d} instance={} scanout=unbound system-caps={x} cursor-flip-war={}",
                .{value.binding.root,value.hardware.heads,value.hardware.windows,value.hardware.channels,value.instance_bound,
                    value.system_caps,(value.system_caps & 0x10) != 0});
            const deadline = owner.deadline; var token = try owner.handoff();
            const finished = owner.state == .finished;
            self.channel = try exchange.Exchange.init(&token, deadline);
            if (finished) self.display_engine_owner = null;
            self.display_engine_active = false; return .progress;
        }
        if (@call(.never_inline, @TypeOf(owner.*).poll, .{owner}) catch |err| { self.rmFailure(.display_engine, owner.binding.root, owner.last_status); return err; }) |dispatch| {
            try self.notification(&owner.exchange, dispatch, current); return .progress;
        }
        return if (owner.exchange.phase == .waiting) .idle else .progress;
    }
    noinline fn advanceFifoOwner(self: *Owner, current: u64, index: anytype) !Progress {
        const owner = self.fifos[index].owner orelse return error.State;
        if (owner.state == .ready or owner.state == .closed) {
            if (owner.state == .ready) try self.rejection(.channel, owner.config.handle, owner.rejected, owner.host_rejected);
            if (owner.info()) |fifo_info| self.log("NVIDIA gsp-fifo: channel={x} cid={d} hw-chid={d} runlist={d} token={x} engine={x} scheduled=yes object-class={x}",
                .{fifo_info.config.handle,fifo_info.cid,fifo_info.config.hardware_channel,fifo_info.config.runlist,
                    fifo_info.work_submit_token,fifo_info.config.rm_engine,fifo_info.config.object_class});
            const deadline = owner.deadline; var token = try owner.handoff();
            self.channel = try exchange.Exchange.init(&token, deadline);
            if (owner.awaitingCollection()) self.log("NVIDIA channel-retire: channel={x} epoch={d} RM=returned collection=pending namespace=held",
                .{owner.config.handle, self.epoch});
            if (owner.state == .finished and !owner.awaitingCollection()) try self.freeChannelSlot(index);
            self.fifo_active = null; return .progress;
        }
        if (@call(.never_inline, @TypeOf(owner.*).poll, .{owner}) catch |err| { self.rmFailure(.channel, owner.config.handle, owner.last_status); return err; }) |dispatch| {
            try self.notification(owner.channel().?, dispatch, current); return .progress;
        }
        return if (owner.channel().?.phase == .waiting) .idle else .progress;
    }
    noinline fn advanceContextOwner(self: *Owner, current: u64, index: anytype) !Progress {
        const owner = self.contexts[index].owner orelse return error.State;
        if (owner.state == .ready or owner.state == .closed) {
            if (owner.state == .ready) self.logContextDiscovery(owner);
            if (owner.state == .ready) try self.rejection(.context, owner.binding.group, owner.rejected, null);
            if (owner.info()) |info| self.log("NVIDIA gsp-context: group={x} share={x} engine={x} runlist={d} timeslice-request-us={d} rejection={?x} commands=bounded fifo=unallocated",
                .{info.binding.group, info.binding.share, info.nv_engine, info.engine.data[3],info.timeslice_requested_us,info.timeslice_rejection});
            const deadline = owner.deadline; var token = try owner.handoff();
            self.channel = try exchange.Exchange.init(&token, deadline);
            if (owner.state == .finished) try self.freeContextSlot(index);
            self.context_active = null; return .progress;
        }
        if (@call(.never_inline, @TypeOf(owner.*).poll, .{owner}) catch |err| { self.rmFailure(.context, owner.binding.group, owner.last_status); return err; }) |dispatch| {
            try self.notification(&owner.exchange, dispatch, current); return .progress;
        }
        return if (owner.exchange.phase == .waiting) .idle else .progress;
    }
    noinline fn advanceNativeBufferOwner(self: *Owner, current: u64, index: anytype) !Progress {
        const owner = self.native_buffers.items()[index].owner orelse return error.State;
        if (owner.state == .ready or owner.state == .closed) {
            if (owner.state == .ready) try self.rejection(.native_buffer, owner.binding.memory, owner.rejected, null);
            if (owner.state == .ready) if (owner.host_rejected) |status| try self.recordFault(.{ .source = .host,
                .kind = if (status == r4os.abi.gfx_buffer_error_oom or status == r4os.abi.gfx_buffer_error_budget or status == r4os.abi.gfx_buffer_error_capacity) .resource else .unknown,
                .operation = .native_buffer, .rm_handle = owner.binding.memory, .code = @as(u32, @bitCast(status)) });
            const deadline = owner.deadline;
            var token = try owner.handoff();
            self.channel = try exchange.Exchange.init(&token, deadline);
            if (owner.state == .finished) try self.freeNativeSlot(index);
            self.native_active = null;
            return .progress;
        }
        if (@call(.never_inline, @TypeOf(owner.*).poll, .{owner}) catch |err| { self.rmFailure(.native_buffer, owner.binding.memory, owner.last_status); return err; }) |dispatch| {
            try self.notification(&owner.exchange, dispatch, current);
            return .progress;
        }
        return if (owner.exchange.phase == .waiting) .idle else .progress;
    }
    noinline fn advanceBufferOwner(self: *Owner, current: u64, index: anytype) !Progress {
        const slot = &self.buffers.items()[index];
        const owner = slot.owner orelse return error.State;
        if (owner.state == .ready or owner.state == .closed) {
            if (owner.state == .ready) try self.rejection(.mapping, owner.reservation.object(0) catch 0, owner.rejected, owner.host_rejected);
            var token = try owner.handoff(owner.deadline);
            self.channel = try exchange.Exchange.init(&token, owner.deadline);
            if (owner.state == .finished and !owner.awaitingCollection()) try self.freeBufferSlot(index);
            self.buffer_active = null;
            return .progress;
        }
        if (@call(.never_inline, @TypeOf(owner.*).poll, .{owner}) catch |err| { self.rmFailure(.mapping, owner.reservation.object(0) catch 0, owner.last_status); return err; }) |dispatch| {
            try self.notification(&owner.exchange, dispatch, current);
            return .progress;
        }
        return if (owner.exchange.phase == .waiting) .idle else .progress;
    }
    fn freeBufferSlot(self: *Owner, index: usize) !void {
        const slot = &self.buffers.items()[index];
        const owner = slot.owner orelse return error.State;
        if (owner.state != .finished or owner.namespace_live or owner.awaitingCollection()) return error.Retained;
        const heap = slot.heap orelse return error.Api;
        if (heap.release(slot.allocation.handle) != r4os.abi.driver_heap_ok) return error.Retained;
        if (slot.evicting) self.mapping_evictions +|= 1;
        slot.* = .{};
    }
    fn collectDeferredChannel(self: *Owner) !bool {
        for (&self.fifos, 0..) |*slot, index| if (slot.owner) |owner| {
            if (!owner.awaitingCollection() or (owner.state != .finished and owner.state != .handed_off)) continue;
            // No RM exchange is borrowed while the epoch-wide barrier waits
            // for other native BOs. Keep the namespace until its exact ack.
            if (!try owner.collectDeferred()) return false;
            self.log("NVIDIA channel-retire: channel={x} epoch={d} collection=complete namespace=released",
                .{owner.config.handle, self.epoch});
            if (owner.state == .finished) try self.freeChannelSlot(index);
            return true;
        };
        return false;
    }
    fn collectDeferredBuffer(self: *Owner) !bool {
        for (self.buffers.items(), 0..) |*slot, index| if (slot.owner) |owner| {
            if (!owner.awaitingCollection() or (owner.state != .finished and owner.state != .handed_off)) continue;
            // One deferred owner per slice. A busy global barrier must still
            // let the active RM owner and native release-ticket queue advance.
            if (!try owner.collectDeferred()) return false;
            if (owner.state == .finished) try self.freeBufferSlot(index);
            return true;
        };
        return false;
    }
    noinline fn observePower(self: *Owner, current: u64) void {
        if (self.power_owner) |*owner| {
            owner.observeActivity(current, self.powerActivity());
            owner.sample(current) catch |err| {
                if (owner.host_failure == null) self.log("NVIDIA telemetry: read-unavailable={s}", .{@errorName(err)});
                owner.host_failure = err;
            };
            owner.exchangeCommon(current) catch |err| {
                if (owner.host_failure == null) self.log("NVIDIA telemetry: common-unavailable={s}", .{@errorName(err)});
                owner.host_failure = err;
            };
        }
    }
    noinline fn advanceUnload(self: *Owner, current: u64) !Progress {
        const owner = &self.unload;
        if (!self.graph_closing or self.graph == null or self.graph.?.state != .finished or
            self.activeChannel() != &self.channel.? or owner.channel != &self.channel.? or
            owner.deadline != self.close_deadline) return error.Binding;
        switch (owner.phase) {
            .request => {
                if (try owner.poll()) |dispatch| try self.notification(&self.channel.?, dispatch, current);
                return if (owner.phase == .request) .idle else .progress;
            },
            .processor_wait => {
                const mailbox = try self.device.?.readProcessorSuspend(owner, owner.deadline);
                if (!try owner.observe(mailbox)) return .idle;
                self.log("NVIDIA gsp-unload: RPC=acked processor=suspended mailbox={x} epoch={d} firmware-teardown=next resources=held", .{mailbox,self.epoch});
                // Existing Device teardown follows. Keep its conservative
                // retention until the separate full shutdown path proves DMA
                // and display retirement; this is not a resource-release token.
                return error.RmClosed;
            },
            else => return error.State,
        }
    }
    noinline fn advanceStartup(self: *Owner, current: u64, channel: *exchange.Exchange) !Progress {
        if (self.graph) |*graph| {
            switch (graph.state) {
                .ready => {
                    var loan = try graph.loan(graph.deadline);
                    self.channel = try exchange.Exchange.init(&loan.runtime, graph.deadline);
                    self.display_object = loan.object;
                    self.log("NVIDIA gsp-rm: objects=ready client={x} device={x} subdevice={x} display={x} events=HPD,DP native-output=unavailable",
                        .{graph.base.plan.handles.client, graph.base.plan.handles.device, graph.base.plan.handles.subdevice, loan.object.display});
                    if (self.nativeAddressSpace()) |info|
                        self.log("NVIDIA gsp-vaspace: handle={x} base={x} bytes={x} big-page={d} page-tables={s} app-mappings=none",
                            .{info.handle, info.base, info.bytes, info.big_page_bytes, if (info.host != null) @as([]const u8, "host-external") else "RM"})
                    else self.log("NVIDIA gsp-vaspace: unavailable rm={?} receiver-inventory=available", .{graph.address_space.?.rejected});
                    if (self.nativeMemoryCapabilities()) |caps|
                        self.log("NVIDIA gsp-memory-caps: raw={x},{x},{x} system-render={} system-scanout={} gpu-cache={} blocklinear={} gob-bytes={d} generic-kind={x} engines=unqualified",
                            .{caps.raw[0], caps.raw[1], caps.raw[2], caps.renderSystem(), caps.scanoutSystem(), caps.gpuCachedSystem(), caps.blocklinear(), caps.gobBytes(), caps.genericPageKind()})
                    else self.log("NVIDIA gsp-memory-caps: unavailable native-layouts=unqualified", .{});
                    if (self.nativeControlBuffer()) |info|
                        self.log("NVIDIA gsp-control: memory={x} virtual={x} gpu-va={x} bytes={d} backing=BO pages=system-linear gpu-cache=disabled channels=none",
                            .{info.memory, info.virtual, info.address, info.bytes})
                    else if (graph.control_buffer) |*owner|
                        self.log("NVIDIA gsp-control: unavailable rm={?} host={s} receiver-inventory=available",
                            .{owner.rejected, if (owner.host_rejected) |err| @errorName(err) else "none"});
                    return .progress;
                },
                .rejected => {
                    // A validated RM rejection was ACKed by its exact owner.
                    // Destroy only the proven live prefix, in reverse order.
                    const status = if (graph.subscriptions) |*owner| blk: {
                        const result = owner.last_status orelse return error.State;
                        break :blk if (result.result == .rm_error) result.result.rm_error else return error.State;
                    } else blk: {
                        const result = graph.base.last_status orelse return error.State;
                        break :blk if (result.result == .rm_error) result.result.rm_error else return error.State;
                    };
                    self.rm_rejection = status;
                    const end = @min(self.startup_deadline, try std.math.add(u64, current, 5 * std.time.ns_per_s));
                    self.log("NVIDIA gsp-rm: rejected status={x} cleanup=proven-objects deadline-ns={d}", .{status, end});
                    try graph.beginDestroy(end);
                    return .progress;
                },
                .closed => {
                    var token = try graph.finish(graph.deadline);
                    self.channel = try exchange.Exchange.init(&token, graph.deadline);
                    if (!self.graph_closing) return error.RmRejected;
                    try self.unload.open(&self.channel.?, self.close_deadline);
                    self.log("NVIDIA gsp-unload: RM-objects=closed request=47 epoch={d} resources=held", .{self.epoch});
                    return .progress;
                },
                .base_creating, .i2c_creating, .vaspace_creating, .control_creating, .events_creating, .events_destroying, .control_destroying, .vaspace_destroying, .i2c_destroying, .base_destroying => {
                    if (try @call(.never_inline, rm.Owner.poll, .{graph})) |dispatch| {
                        try self.notification(self.activeChannel() orelse return error.State, dispatch, current);
                        return .progress;
                    }
                    return if ((self.activeChannel() orelse return error.State).phase == .waiting) .idle else .progress;
                },
                .loaned => {},
                else => return error.State,
            }
        }
        if (self.static_info != null and self.post.state != .complete and channel.phase == .idle) {
            if (self.post.self_address == 0) try self.post.open(channel, &self.static_info.?);
            const end = @min(self.startup_deadline, try std.math.add(u64, current, 5 * std.time.ns_per_s));
            try self.post.prepare(end);
            self.log("NVIDIA gsp-postinit: command={x} gpc={d} deadline-ns={d}", .{@intFromEnum(self.post.command), self.post.gpc, end});
            return .progress;
        }
        // A fresh idle observation gets a new bound. Pending messages and
        // sequencer phases keep their original deadline across rescheduling.
        const deadline = channel.deadline orelse (std.math.add(u64, current, std.time.ns_per_s) catch return error.Clock);
        if (try channel.poll(deadline)) |dispatch| {
            if (dispatch.response) {
                if (self.static_info != null) {
                    try self.post.accept(dispatch);
                    if (self.post.snapshot()) |info|
                        self.log("NVIDIA gsp-postinit: gpcs={d} tpcs={d} intr-entries={d} gsp-stall={d} irq=awaiting-owner native-output=unavailable",
                            .{@popCount(info.gpc_mask), info.tpc_count, info.entry_count, info.entries[info.gsp_index.?].stall});
                    return .progress;
                }
                if (channel.function != static.function) return error.Unexpected;
                const info = try static.decode(dispatch.record, self.physical_bytes);
                try self.memory_inventory.prepare(self.reservation.?, &info, self.epoch);
                try channel.complete(dispatch.ticket);
                self.static_info = info; // Publish no observation before a successful ACK.
                try self.memory_inventory.publish();
                self.log("NVIDIA gsp-static: client={x} device={x} subdevice={x} fb-bytes={d} regions={d} bar1-pdb={x} bar2-pdb={x}",
                    .{info.client, info.device, info.subdevice, info.fb_bytes, info.region_count, info.bar1_pdb, info.bar2_pdb});
                self.log("NVIDIA gsp-static: split-vas={any} requested-split-vas=false mapping=awaiting-receipt", .{info.split_vas});
                self.logMemory();
                return .progress;
            }
            try self.notification(channel, dispatch, current);
            return .progress;
        }
        if (self.rm_enabled and self.graph == null and self.post.snapshot() != null and channel.phase == .idle and !channel.in_lockdown) {
            const end = @min(self.startup_deadline, try std.math.add(u64, current, 5 * std.time.ns_per_s));
            var token = try channel.handoff(end);
            // Nouveau r570's kernel client uses processID=~0 and an empty
            // name. This is not a fabricated R4OS program or host pointer.
            self.graph = @as(rm.Owner, undefined);
            errdefer self.graph = null;
            try self.graph.?.initInPlace(&token, std.math.maxInt(u32), "", end);
            self.graph.?.control_context = self.ctx;
            self.graph.?.control_adapter = self.adapter_id;
            self.graph.?.host_mmu_io = .{ .context = self, .generation = hostMmuGeneration, .now_ns = hostMmuNow,
                .read32 = hostMmuRead, .write32 = hostMmuWrite };
            self.log("NVIDIA gsp-rm: creating client={x} deadline-ns={d}", .{self.graph.?.reservation.client, end});
            return .progress;
        }
        if (try self.beginReceiverRefresh(current)) return .progress;
        // No busy wait or raw-log dump on every empty queue. One ring per
        // second bounds DMA copying and output, even under continual logging.
        if (current >= self.next_log and self.reader.?.enabled) {
            self.next_log = current +| std.time.ns_per_s;
            try self.captureLog(deadline);
        }
        return .idle;
    }
    fn hostMmuOwner(raw: *anyopaque) *Owner { return @ptrCast(@alignCast(raw)); }
    fn hostMmuGeneration(raw: *anyopaque) u64 {
        const self = hostMmuOwner(raw);
        return if (self.self_address == @intFromPtr(self) and self.failure == null) self.epoch else 0;
    }
    fn hostMmuNow(raw: *anyopaque) u64 {
        const self = hostMmuOwner(raw);
        const device = self.device orelse return std.math.maxInt(u64);
        return if (device.clock) |timer| timer.nowNs() else std.math.maxInt(u64);
    }
    fn hostMmuRead(raw: *anyopaque, address: u32) !u32 {
        const self = hostMmuOwner(raw);
        const vm = if (self.graph) |*graph| if (graph.address_space) |*space| &space.host_vm else return error.State else return error.State;
        return (self.device orelse return error.State).hostMmuRead(vm, address);
    }
    fn hostMmuWrite(raw: *anyopaque, address: u32, value: u32) !void {
        const self = hostMmuOwner(raw);
        const vm = if (self.graph) |*graph| if (graph.address_space) |*space| &space.host_vm else return error.State else return error.State;
        return (self.device orelse return error.State).hostMmuWrite(vm, address, value);
    }
    fn beginReceiverRefresh(self: *Owner, current: u64) !bool {
        if (self.shutdown_closing or !self.discover_receivers) return false;
        if (self.anyAdaptiveRefresh() or self.refresh_quiescing) return false;
        const channel = if (self.channel) |*value| value else return false;
        if (self.graph_closing or self.graph == null or self.graph.?.state != .loaned or channel.phase != .idle or channel.in_lockdown or
            self.copyBusy() or self.cursor_point != null or
            (self.outputs.state != .detached and !try self.receiver_events.due(self.epoch, current))) return false;
        const end = try std.math.add(u64, current, 10 * std.time.ns_per_s);
        self.output_generation = try std.math.add(u64, self.output_generation, 1);
        if (std.mem.allEqual(u8, &self.outputs.mst_store.seed, 0)) {
            var bytes: [32]u8 = @splat(0);
            std.mem.writeInt(u64, bytes[0..8], self.epoch, .little);
            std.mem.writeInt(u64, bytes[8..16], self.startup_deadline, .little);
            std.mem.writeInt(u64, bytes[16..24], current, .little);
            std.mem.writeInt(u32, bytes[24..28], self.adapter_id, .little);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(&bytes, &digest, .{});
            self.outputs.mst_store.seed = digest[0..16].*;
        }
        var token = try channel.handoff(end);
        try self.graph.?.reclaim(&token, end);
        try self.outputs.begin(&self.graph.?, self.output_generation, end);
        try self.receiver_events.started(self.epoch, current);
        self.log("NVIDIA gsp-outputs: acquiring generation={d} deadline-ns={d}", .{self.output_generation, end});
        return true;
    }
    fn powerStopping(self: *const Owner) bool {
        return if (self.power_owner) |*owner| owner.stopping else false;
    }
    pub fn powerActivity(self: *const Owner) power.policy.Activity {
        // Bootstrap/context construction stays under firmware defaults.
        // Host policy follows accepted application jobs and published outputs.
        var published = false;
        for (&self.presentation_slots) |*slot| if (slot.*) |*image| if (image.registered) { published = true; };
        var result: power.policy.Activity = .{
            .copy = self.copy_job != null,
            .render = self.queued_render != null or (if (self.graphics_work) |*work| work.queued else false),
            .display_commit = published and (self.display_work != null or self.hasDisplayFlips()),
            .cursor = published and (self.cursor_upload != null or self.cursor_point != null),
            .fullscreen = self.direct_work != null,
            .stopping = self.graph_closing or self.shutdown_closing,
        };
        for (&self.work_slots) |*slot| {
            switch (slot.*) {
                .copy => result.copy = true,
                .render => result.render = true,
                .native => |*work| mergeEngineActivity(&result, work.powerActivity()),
                .free => {},
            }
        }
        // A public batch already has the exact admitted job above. Its
        // channel can support a broader mask and must not reclassify it.
        // Private batches use their still-bound, generation-matched owner.
        if (self.batch_work) |*work| if (work.native_fence == null and work.receipt == null) {
            const handle = work.channel_handle;
            if (handle.epoch == self.epoch and handle.serial != 0 and handle.slot < self.fifos.len and
                self.fifos[handle.slot].serial == handle.serial)
            {
                if (self.fifos[handle.slot].owner) |fifo| if (fifo.config.engine != .none)
                    mergeEngineActivity(&result, native_queue.activityForEngines(fifo.config.engine_mask));
            }
        };
        for (&self.display_images) |*image| if (image.* != null) { result.outputs += 1; };
        return result;
    }
    fn mergeEngineActivity(result: *power.policy.Activity, activity: power.policy.Activity) void {
        inline for (.{ "copy", "render", "video", "compute" }) |field|
            @field(result, field) = @field(result, field) or @field(activity, field);
    }
    fn beginPower(self: *Owner, current: u64) !bool {
        if (!self.power_enabled or !self.rm_enabled or self.power_active or self.copyBusy() or self.cursor_point != null or
            self.cursor_reserving or self.fifo_active != null or self.context_active != null or self.virtuals.active_range != null or self.native_active != null or
            self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or self.graph_closing or
            self.nativeObject() == null or self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return false;
        // Shutdown may drain an already attached RUSD/boost owner, but must
        // not create a telemetry owner after kernel admission has closed.
        const owner = if (self.shutdown_closing)
            (if (self.power_owner) |*value| value else return false)
        else (try self.ensurePower()) orelse return false;
        const operation = (try owner.choose(current, self.powerActivity())) orelse return false;
        const deadline = current +| std.time.ns_per_s;
        var token = try self.channel.?.handoff(deadline);
        try owner.begin(&token, operation, current, deadline);
        self.power_active = true;
        return true;
    }
    /// Driver Work only; the common query merely queues bounded demand.
    pub fn demandPower(self: *Owner, current: u64, mask: u64) !void {
        if (self.graph_closing) return error.Busy;
        const owner = (try self.ensurePower()) orelse return error.Unsupported;
        try owner.demand(current, mask);
    }
    noinline fn ensurePower(self: *Owner) !?*power.Owner {
        if (!self.power_enabled or !self.rm_enabled or self.nativeObject() == null) return null;
        if (self.power_owner == null) {
            const ctx = self.ctx orelse return null;
            const names = self.graph.?.base.plan.handles;
            const internal = self.static_info orelse return error.State;
            self.power_owner = try power.Owner.init(ctx, self.adapter_id,
                .{ .epoch = self.epoch, .client = names.client, .subdevice = names.subdevice },
                .{ .epoch = self.epoch, .client = internal.client, .subdevice = internal.subdevice });
        }
        return &self.power_owner.?;
    }
    fn logMemory(self: *Owner) void {
        const data = self.nativeMemory() orelse return;
        self.log("NVIDIA gsp-memory: epoch={d} physical={d} reported={d} regions={d} holes={d} rm-budget={d} retained={d} screened={d} allocation=none",
            .{data.epoch, data.physical_bytes, data.reported_bytes, data.region_count, data.region_holes,
                data.speculative_reserved, data.retained_bytes, data.screened_bytes});
        self.log("NVIDIA gsp-memory: union={d} surface-extents={d} table-pages={d} instance={any} payload-extents={d} firmware-layout-matches={any}",
            .{data.retained_count, data.surface_extents, data.table_pages, data.instance_active, data.payload_extents, data.firmware_layout_matches});
        self.log("NVIDIA gsp-memory: layout-reported={any} layout-usable={any} non-wpr={x} frts={x} application-placement=host-regions",
            .{data.firmware_layout_reported, data.firmware_layout_usable, data.non_wpr_heap, data.frts});
        for (data.windows) |bar|
            self.log("NVIDIA gsp-aperture: pci-bar={d} base={x} bytes={d} status={s} prefetch={any} rebar-present={any} resize=no",
                .{bar.pci_index, bar.base, bar.bytes, @tagName(bar.status), bar.prefetchable, data.rebar_present});
        for (self.memory_inventory.regions[0..data.region_count], 0..) |*region, index|
            self.log("NVIDIA gsp-region: index={d} base={x} bytes={d} rm-budget={d} protected={any} iso={any} compressed={any} performance={d}",
                .{index, region.base, region.bytes, region.reserved, region.protected, region.iso, region.compressed, region.performance});
        self.logResidency();
    }
    fn notification(self: *Owner, channel: *exchange.Exchange, dispatch: exchange.Dispatch, current: u64) !void {
        if (dispatch.response) return error.Unexpected;
        const source = self.outputs.channel();
        if (source != null and &source.?.exchange != channel) return error.Binding;
        if (dispatch.record.rpc.function == @intFromEnum(boot.Kind.cpu_sequencer)) {
            try self.outputs.invalidate();
            // Firmware register sequences can invalidate a capture too.
            // Retry that capture through its existing finite budget; outside
            // acquisition request one refresh without inventing HPD masks.
            if (!self.receiver_events.capturing and self.presentation != null) try self.receiver_events.refresh(self.epoch, current);
            const limits = @import("gsp_sequencer.zig").Limits{
                .default_timeout_ns = std.time.ns_per_s, .poll_interval_ns = std.time.ns_per_ms,
                .register_bytes = self.device.?.window.byte_length,
            };
            if (source) |owner| try self.sequence.beginDisplay(self.device.?, owner, limits) else try self.sequence.begin(self.device.?, channel, limits);
            return;
        }
        const sink = events.Sink{
            .context = self, .generation = generation, .admit = admit, .deliver = deliver,
        };
        // Journal/XID/lockdown delivery does not mutate a receiver capture.
        // Exact registered HPD/DP events invalidate it in their own handler;
        // fatal diagnostics still quarantine after the receipt is ACKed.
        self.ordinary = if (source) |owner| try events.Dispatch.initDisplay(owner, sink) else try events.Dispatch.init(channel, sink);
        try self.ordinary.?.step();
        self.faults.acknowledge(self.ordinary.?.scope);
        if (self.faults.first_fatal) |*record| self.log("NVIDIA gsp-fault: first={d} receipt-ack={} quiescence=unproven callback-executed=no",
            .{record.serial, record.acknowledged});
        self.snapshot.events +|= 1;
        self.snapshot.last_event_ns = current;
        self.ordinary = null;
        if (self.faults.pending) return error.DeviceLost;
    }
    fn from(raw: *anyopaque) *Owner { return @ptrCast(@alignCast(raw)); }
    fn generation(raw: *anyopaque) u64 {
        const self = from(raw);
        _ = self.now() catch return 0;
        return self.epoch;
    }
    fn admit(raw: *anyopaque, scope: events.Scope, event: events.Event) error{ Denied, Unsupported }!void {
        const self = from(raw);
        if (generation(raw) != scope.epoch or self.epoch != scope.epoch) return error.Denied;
        // Diagnostics/lockdown stay here. Display changes require an exact
        // live RM event registration; other effects still need their owners.
        switch (event) {
            .libos_print, .lockdown, .os_error, .nocat, .rc_triggered, .mmu_fault_queued, .fecs_error, .recovery_action => {},
            .post_event => {
                const graph = if (self.graph) |*value| value else return error.Unsupported;
                const sink = graph.eventSink() catch return error.Denied;
                try sink.admit(sink.context, scope, event);
            },
            else => return error.Unsupported,
        }
    }
    fn deliver(raw: *anyopaque, scope: events.Scope, event: events.Event) !void {
        const self = from(raw);
        // Record before ACK; stop only after Dispatch completes. Stopping in
        // this callback would invalidate its owner and strand every receipt.
        if (diagnostics.event(scope, event, self.last_clock)) |record| try self.recordFault(record);
        switch (event) {
            .libos_print => |v| self.logBytes("print", v.engine, v.bytes),
            .lockdown => {}, // Exchange owns engage-before-I/O and release-after-ACK.
            .rc_triggered, .mmu_fault_queued, .fecs_error, .recovery_action => {}, // Diagnostic quarantine; no fabricated recovery callback.
            .post_event => |post| {
                const graph = if (self.graph) |*value| value else return error.Unsupported;
                const sink = try graph.eventSink();
                try sink.deliver(sink.context, scope, event);
                const kind = (try post.display()) orelse return error.Unexpected;
                try self.outputs.invalidate();
                // The capture generation changed before this query could
                // publish. Drain its reply, but never admit its old result.
                if (self.mode_control_active) try self.invalidateModeQuery();
                try self.receiver_events.note(self.epoch, self.last_clock, kind);
                if (kind == .hotplug) self.snapshot.hotplug_events +|= 1 else self.snapshot.dp_irq_events +|= 1;
                self.log("NVIDIA gsp-event: kind={s} status={x} data={x} refresh=required", .{@tagName(kind), post.status, post.data});
            },
            .os_error => |v| {
                self.snapshot.xid_count +|= 1;
                self.snapshot.last_xid = v.xid;
                self.log("NVIDIA gsp-xid: xid={d} previous={d} runlist={d} channel={d}", .{v.xid, v.previous_xid, v.runlist, v.channel});
                self.logBytes("xid-text", v.xid, v.text);
            },
            .nocat => |v| {
                self.snapshot.nocat_count +|= 1;
                self.log("NVIDIA gsp-nocat: flags={x} type={d} bugcheck={x} subsystem={d} error={x} tdr={d} diagnostic-bytes={d}",
                    .{v.flags, v.record_type, v.bugcheck, v.subsystem, v.error_code, v.tdr_reason, v.diagnostic.len});
                self.logBytes("nocat-source", v.subsystem, v.source);
                self.logBytes("nocat-engine", v.subsystem, v.engine);
                self.logNocatBytes(v.diagnostic);
            },
            else => return error.Unsupported,
        }
    }
    fn captureLog(self: *Owner, deadline: u64) !void {
        const index = self.log_index;
        self.log_index = (index + 1) % init.log_count;
        const observed = self.reader.?.capture(index, deadline, &self.words) catch |err| {
            if (err == error.ProducerChanged) {
                self.snapshot.moving_logs +|= 1;
                return;
            }
            return err;
        };
        self.snapshot.raw_words +|= observed.word_count;
        self.snapshot.lost_words +|= observed.lost_words;
        if (observed.word_count != 0 or observed.lost_words != 0) {
            self.log("NVIDIA gsp-log: ring={d} first={d} next={d} words={d} lost={d} raw=uninterpreted",
                .{index, observed.first_word, observed.next_word, observed.word_count, observed.lost_words});
        }
    }
    fn log(self: *Owner, comptime format: []const u8, args: anytype) void {
        var buffer: [256]u8 = undefined;
        const line = std.fmt.bufPrintZ(&buffer, format, args) catch return;
        self.ctx.?.logInfo(line);
    }
    noinline fn logContextDiscovery(self: *Owner, owner: *const execution_context.Owner) void {
        const data = &owner.discovery;
        if (owner.copy_caps) |caps| self.log("NVIDIA gsp-context-copy: rm-engine={d} caps={x}/{x} grce={} sysmem={} standalone={}",
            .{owner.rm_engine, caps.bytes[0], caps.bytes[1], caps.grce(), caps.sysmem(), caps.standalone()});
        self.log("NVIDIA gsp-context-discovery: rm-engine={d} state={s} operation={s} unavailable={s} rejection={?x} classes-acked={} count={d} required={x}",
            .{owner.rm_engine, @tagName(owner.state), if (owner.operation) |op| @tagName(op) else "none",
                if (owner.unavailable) |reason| @tagName(reason) else "none", owner.rejected,
                data.classes_acked, data.class_count, data.required_classes});
        self.log("NVIDIA gsp-context-engines: acked-pages={d} rows={d} mask={x}/{x}/{x}/{x} other={d} selected={} method-bytes={d}",
            .{data.engine_pages, data.engine_rows, data.engine_mask[0], data.engine_mask[1], data.engine_mask[2], data.engine_mask[3],
                data.other_engines, owner.selected != null, owner.method_bytes});
        if (owner.selected) |selected| {
            if (execution_context.wire.videoEngine(owner.rm_engine)) self.log("NVIDIA gsp-context-falcon: rm-engine={d} eng-desc={x} bytes={d} held={}",
                .{owner.rm_engine, selected.data[0], owner.falcon_bytes, owner.falcon_buffer.info() != null});
            self.log("NVIDIA gsp-context-topology: rm-engine={d} runlist={d} pri={x} pbdmas={d} ids={x}/{x} paired-copy={?}",
                .{owner.rm_engine, selected.data[3], selected.data[11], selected.count,
                    selected.pbdma[0], selected.pbdma[1], owner.copies.paired(selected)});
            if (owner.rm_engine == 1) for (&owner.copies.rows, 0..) |*row, index| {
                if (!row.present) continue;
                self.log("NVIDIA gsp-context-ce-row: rm-engine={d} runlist={d} pri={x} pbdmas={d} ids={x}/{x}",
                    .{index + 9, row.runlist, row.base, row.count, row.pbdma[0], row.pbdma[1]});
            };
        }
        if (!data.classes_acked or owner.unavailable != .classes) return;
        var offset: usize = 0;
        while (offset < data.class_count) {
            const count: usize = @min(8, data.class_count - offset);
            var buffer: [120]u8 = undefined;
            var used: usize = 0;
            for (data.class_ids[offset..][0..count]) |class| {
                const word = std.fmt.bufPrint(buffer[used..], " {x}", .{class}) catch return;
                used += word.len;
            }
            self.log("NVIDIA gsp-context-classes: offset={d} ids={s}", .{offset, buffer[0..used]});
            offset += count;
        }
    }
    fn logBytes(self: *Owner, kind: []const u8, source: u32, bytes: []const u8) void {
        var escaped: [160]u8 = undefined;
        const count = @min(bytes.len, escaped.len);
        for (bytes[0..count], escaped[0..count]) |byte, *out| out.* = if (byte >= 32 and byte < 127) byte else '.';
        self.log("NVIDIA gsp-runtime: {s} source={d} bytes={d} text={s}", .{kind, source, bytes.len, escaped[0..count]});
    }
    noinline fn logRpcBytes(self: *Owner, kind: []const u8, bytes: []const u8) void {
        const count: usize = @min(bytes.len, 160);
        var offset: usize = 0;
        while (offset < count) {
            const part: usize = @min(count - offset, 32);
            var block: [32]u8 = @splat(0);
            @memcpy(block[0..part], bytes[offset..][0..part]);
            const hex = std.fmt.bytesToHex(block, .lower);
            self.log("NVIDIA gsp-rpc-data: kind={s} bytes={d} captured={d} offset={d} hex={s}",
                .{kind, bytes.len, count, offset, hex[0 .. part * 2]});
            offset += part;
        }
    }
    noinline fn logNocatBytes(self: *Owner, bytes: []const u8) void {
        // The decoded journal owns at most 1024 inline bytes. Preserve binary
        // diagnostics before its normal ACK, without new MMIO/RPC or storage.
        const count: usize = @min(bytes.len, 1024);
        var offset: usize = 0;
        while (offset < count) {
            const part: usize = @min(count - offset, 32);
            var block: [32]u8 = @splat(0);
            @memcpy(block[0..part], bytes[offset..][0..part]);
            const hex = std.fmt.bytesToHex(block, .lower);
            self.log("NVIDIA gsp-nocat-data: epoch={d} event={d} bytes={d} captured={d} offset={d} hex={s}",
                .{self.epoch, self.snapshot.nocat_count, bytes.len, count, offset, hex[0 .. part * 2]});
            offset += part;
        }
    }
};
