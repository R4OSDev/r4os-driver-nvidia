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
pub const diagnostics = @import("gsp_faults.zig");
const logs = @import("gsp_logs.zig");
const init = @import("gsp_init.zig");
const static = @import("gsp_static.zig");
const postinit = @import("gsp_postinit.zig");
const rm = @import("gsp_rm_graph.zig");
const display = @import("gsp_display_rpc.zig");
pub const display_engine = @import("gsp_display_engine.zig");
pub const DisplayEngineHandle = struct { epoch: u64, root: u32 };
pub const DisplayEngineStatus = struct { state: display_engine.State, info: ?display_engine.Info, rejected: ?u32, unavailable: bool };
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
};
pub const PositionSubmission = struct {
    handle: DisplayChannelHandle,
    config: display_channel.push.commands.Config,
    phase: DisplayPhase = .prepare,
    ticket: ?display_channel.push.Ticket = null,
};
pub const DisplayPosition = struct { handle: DisplayChannelHandle, point: display_channel.push.commands.Point, sequence: u64 };
pub const boot_mode = @import("gsp_boot_mode.zig");
pub const hdmi_link = @import("gsp_hdmi_link.zig");
pub const DisplayLink = struct { plan: hdmi_link.Plan, acknowledged: u8, receipt: u64 };
pub const DisplayWork = struct { core: DisplaySubmission, window: ?DisplaySubmission = null, position: ?PositionSubmission = null, deadline: u64, boot_mode: ?boot_mode.Plan = null, link: ?hdmi_link.Work = null };
pub const ActiveDisplayImage = struct { image: display_resources.image.Image, head: u32, core_point: u64, window_point: u64, boot_mode: ?boot_mode.Plan = null, position: ?DisplayPosition = null, link: ?DisplayLink = null };
const subscriptions = @import("gsp_event_objects.zig");
const outputs = @import("gsp_outputs.zig");
const inventory = @import("gsp_memory_inventory.zig");
pub const buffer_mapping = @import("gsp_buffer_mapping.zig");
pub const vram = @import("gsp_vram.zig");
pub const execution_fifo = @import("gsp_fifo.zig");
pub const ChannelHandle = struct { epoch: u64, serial: u64, slot: u16 };
pub const ChannelStatus = struct { state: execution_fifo.State, info: ?execution_fifo.Info, rejected: ?u32, host_rejected: ?anyerror };
const ChannelSlot = struct { owner: ?*execution_fifo.Owner = null, allocation: r4os.abi.DriverHeapAllocation = .{}, heap: ?r4os.r4dev.DriverHeapContext = null, serial: u64 = 0 };
const CopyAddress = struct { address: u64, bytes: u64 };
pub const present = @import("gsp_present.zig");
pub const Presentation = struct {
    surface: present.Owner = .{}, channel_handle: ChannelHandle, root: DisplayEngineHandle, window: DisplayChannelHandle,
    binding: r4os.abi.GfxBackendBinding = .{}, pending: bool = false, registered: bool = false,
    initial_point: u32 = 0,
    initial_failure: ?anyerror = null,
};
pub const InitialImage = struct { operation: present.Initial = .{}, mapping: ?BufferHandle = null, deadline: u64 };
pub const InitialImageStatus = struct { pending: bool, completed: u32, failure: ?anyerror };
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
    transfer: ?execution_fifo.copy.wire.Transfer = null,
};
pub const execution_context = @import("gsp_context.zig");
pub const ContextHandle = struct { epoch: u64, serial: u64, slot: u16 };
pub const ContextStatus = struct { state: execution_context.State, info: ?execution_context.Info, rejected: ?u32, unavailable: ?execution_context.Unavailable };
const ContextSlot = struct { owner: ?*execution_context.Owner = null, allocation: r4os.abi.DriverHeapAllocation = .{}, heap: ?r4os.r4dev.DriverHeapContext = null, serial: u64 = 0 };
pub const BufferHandle = struct { epoch: u64, serial: u64, slot: u16 };
pub const BufferStatus = struct { state: buffer_mapping.State, info: ?buffer_mapping.Info, rejected: ?u32, host_rejected: ?buffer_mapping.Error };
const BufferSlot = struct { owner: ?*buffer_mapping.Owner = null, allocation: r4os.abi.DriverHeapAllocation = .{}, heap: ?r4os.r4dev.DriverHeapContext = null, serial: u64 = 0, pending_source: r4os.abi.GfxBufferReference = .{} };
pub const NativeBufferStatus = struct { state: vram.State, info: ?vram.Info, rejected: ?u32, host_rejected: ?i32 };
const NativeBufferSlot = struct { owner: ?*vram.Owner = null, allocation: r4os.abi.DriverHeapAllocation = .{}, heap: ?r4os.r4dev.DriverHeapContext = null, serial: u64 = 0 };
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
    memory_inventory: inventory.Owner = .{},
    physical_bytes: u64 = 0,
    startup_deadline: u64 = 0,
    post: postinit.Owner = .{},
    rm_enabled: bool = false, // Set by the real device only after IRQ installation.
    graph: ?rm.Owner = null,
    display_object: ?display.Object = null,
    display_engine_owner: ?display_engine.Owner = null,
    display_engine_active: bool = false,
    display_channels: [17]?display_channel.Owner = @splat(null),
    display_channel_active: ?u8 = null,
    display_resources_slot: DisplayResourcesSlot = .{},
    display_upload_job: ?struct { operation: display_upload.Upload = .{}, channel_handle: ChannelHandle } = null,
    display_work: ?DisplayWork = null,
    display_images: [8]?ActiveDisplayImage = @splat(null),
    presentation: ?Presentation = null,
    initial_image: ?InitialImage = null,
    rm_rejection: ?u32 = null,
    outputs: outputs.Owner = .{},
    output_refresh: bool = false,
    output_generation: u64 = 0,
    output_next_ns: u64 = 0,
    buffers: [256]BufferSlot = @splat(.{}),
    buffer_active: ?u16 = null,
    buffer_serial: u64 = 0,
    native_buffers: [256]NativeBufferSlot = @splat(.{}),
    native_active: ?u16 = null,
    fifos: [64]ChannelSlot = @splat(.{}),
    fifo_active: ?u16 = null,
    copy_job: ?CopyJob = null,
    copy_completed: u64 = 0,
    copy_backend: ?struct { queue: r4os.driver_queue.Context, binding: r4os.abi.GfxBackendBinding } = null,
    quarantine_attempted: bool = false,
    quarantine_result: ?i32 = null,
    faults: diagnostics.Journal = .{},
    contexts: [64]ContextSlot = @splat(.{}),
    context_active: ?u16 = null,
    graph_closing: bool = false,
    close_deadline: u64 = 0,
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
        self.device = device;
        self.reader = reader;
        self.reservation = reservation;
        self.epoch = handoff.session.epoch;
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
    pub fn step(self: *Owner) !Progress {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.failure != null) return error.State;
        return self.advance() catch |err| {
            self.stop(err);
            return err;
        };
    }
    /// Logical shutdown invalidates every borrowed inventory and retains the
    /// existing RM/session resources. It is not physical GPU quiescence.
    pub fn stop(self: *Owner, err: anyerror) void {
        if (self.self_address == 0 or self.self_address != @intFromPtr(self) or self.failure != null) return;
        if (self.faults.first_fatal == null and err != error.Stopped and err != error.RmClosed)
            self.recordFault(diagnostics.host(.teardown, err, true)) catch {};
        self.outputs.invalidate() catch {};
        self.memory_inventory.invalidate();
        if (self.display_upload_job) |*work| work.operation.quarantine(err);
        if (self.display_resources_slot.owner) |owner| owner.quarantine();
        self.failure = err;
        // unregister(false) terminalizes the common queue as device-lost but
        // retains reachable jobs. complete(device_lost, false) is not that API.
        // Keep this binding even between jobs and attempt retirement only once.
        if (self.copy_backend) |*backend| if (!self.quarantine_attempted) {
            self.quarantine_attempted = true;
            self.quarantine_result = backend.queue.unregister(&backend.binding, 0);
            self.log("NVIDIA gsp-quarantine: epoch={d} result={d} quiesced=no job-held={} resources=retained",
                .{self.epoch, self.quarantine_result.?, self.copy_job != null});
        };
        if (self.activeChannel()) |channel| {
            self.protocol_failure = channel.fail(error.Handler);
            // A failed token transition can leave only handed-off views.
            // They cannot ACK or poison another owner; stop the one retained
            // session explicitly while the outer device retains its DMA.
            channel.session.stop();
            if (channel.last_rpc) |rpc| self.log("NVIDIA gsp-runtime: failed={s} last-rpc={x} sequence={d} result={x} receipt={s}",
                .{@errorName(err), rpc.function, rpc.sequence, rpc.result, if (channel.session.pending != null) @as([]const u8, "retained") else "none"});
            if (self.post.self_address != 0 and self.post.state != .complete)
                self.log("NVIDIA gsp-postinit: failed={s} command={x} status={x} replies={d}",
                    .{@errorName(err), @intFromEnum(self.post.command), self.post.last_status orelse exchange.message.pending, self.post.replies});
        }
        if (self.graph) |*graph| {
            if (graph.state != .finished) graph.base.exchange.session.rm_names.retain(graph.reservation) catch {};
            self.log("NVIDIA gsp-rm: failed={s} state={s} client={x} rejection={?}",
                .{@errorName(err), @tagName(graph.state), graph.reservation.client, self.rm_rejection});
            if (graph.control_buffer) |*owner|
                self.log("NVIDIA gsp-control: failed={s} operation={s} reply={?} registered={} allocated={} mapped={} retained={}",
                    .{@errorName(err), if (owner.caps_active) "memory-caps" else if (owner.operation) |operation| @tagName(operation) else "none", owner.last_status,
                        owner.registered, owner.allocated, owner.mapped, owner.backing.retained});
        }
        if (self.display_engine_owner) |*owner| self.log("NVIDIA gsp-display-engine: failed={s} root={x} operation={s} status={?} confirmed={} possible={} boot=retained",
            .{@errorName(err),owner.binding.root,if (owner.operation) |op| @tagName(op) else "none",owner.last_status,owner.live,owner.allocation_possible});
        for (&self.display_channels) |*slot| if (slot.*) |*owner| self.log("NVIDIA gsp-display-channel: failed={s} handle={x} class={x} index={d} rm-live={} possible={} control={x} state={x} storage-held={}",
            .{@errorName(err),owner.config.handle,display_channel.wire.class(owner.config.kind),owner.config.index,owner.live,owner.allocation_possible,
                owner.last_control,owner.last_state,owner.backing.retained});
        if (self.display_resources_slot.owner) |owner| self.log("NVIDIA gsp-display-table: failed={s} entries={d} revision={d} published={d} upload-held={} storage=retained",
            .{@errorName(err),owner.table.count,owner.table.revision,owner.table.uploaded_revision,self.display_upload_job != null});
        if (self.display_work) |*work| self.log("NVIDIA gsp-display-push: failed={s} channel={x} phase={s} point={d} notifier={x} storage=retained",
            .{@errorName(err),work.core.handle.handle,@tagName(work.core.phase),if(work.core.ticket)|ticket|ticket.point else 0,if(work.core.notifier.result)|result|result.word else 0});
        if (self.display_work) |*work| if (work.window) |*window| self.log("NVIDIA gsp-display-image: failed={s} window={d} phase={s} point={d} image={x} storage=retained",
            .{@errorName(err),window.config.route.?.window,@tagName(window.phase),if(window.ticket)|ticket|ticket.point else 0,window.config.scanout.?.dma});
        if (self.display_work) |*work| if (work.position) |*position| self.log("NVIDIA gsp-display-position: failed={s} channel={x} phase={s} point={d} storage=retained",
            .{@errorName(err),position.handle.handle,@tagName(position.phase),if(position.ticket)|ticket|ticket.point else 0});
        if (self.initial_image) |*work| self.log("NVIDIA gsp-initial-image: failed={s} submitted={} point={d} source-held={} storage=retained",
            .{@errorName(err),work.operation.submitted,if(work.operation.ticket)|ticket|ticket.point else 0,work.operation.gpu.lease.id != 0});
        if (self.display_work) |*work| if (work.link) |*link| self.log("NVIDIA gsp-hdmi: failed={s} display={x} phase={s} operation={s} replies={d} receipt={d} status={?} rpc={} storage=retained",
            .{@errorName(err),link.plan.mode.signal.display_id,@tagName(link.phase),@tagName(link.operation),link.acknowledged,link.last_receipt,link.last_status,link.rpc_error});
    }
    fn recordFault(self: *Owner, value: diagnostics.Record) !void {
        var record = value;
        record.epoch = self.epoch; record.time_ns = self.last_clock;
        // RM allocation cid and opaque submit tokens are not hardware CHIDs.
        // Engine/runlist and GPU-VA observations identify candidates only.
        for (&self.fifos) |*slot| if (slot.owner) |owner| {
            if (!owner.live or owner.config_stamp == null or owner.config.context.epoch != self.epoch) continue;
            const parent = owner.parent orelse continue;
            const selected = parent.selected orelse continue;
            if (record.runlist) |runlist| if (runlist != selected.data[3]) continue;
            if (record.nv_engine) |nv_engine| if (nv_engine != (execution_context.wire.nvEngine(parent.rm_engine) catch continue)) continue;
            record.candidate_channels += 1;
            if (record.candidate_channels == 1) {
                record.candidate_rm_handle = owner.config.handle; record.candidate_rm_cid = owner.cid;
            } else { record.candidate_rm_handle = 0; record.candidate_rm_cid = 0; }
        };
        if (self.copy_job) |*work| {
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
        if (self.display_upload_job) |*work| {
            if (work.operation.ticket) |ticket| record.copy_point = ticket.point;
            if (record.fault_address) |va| {
                if (work.operation.source_stamp) |src| record.source_address_match = va >= src.address and va - src.address < display_resources.layout.image_bytes;
                if (work.operation.target_stamp) |dst| record.target_address_match = va >= dst.address and va - dst.address < display_resources.layout.image_bytes;
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
        if (kept.text_bytes != 0) self.logBytes("fault-text", @truncate(kept.code), kept.text[0..kept.text_bytes]);
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
        if (err == error.Memory or err == error.Exhausted or err == error.OutOfMemory)
            self.recordFault(diagnostics.host(operation, err, false)) catch {};
    }
    pub fn reportIrq(self: *Owner, endpoint: *const @import("gsp_irq.zig").Owner) void {
        if (self.self_address != @intFromPtr(self) or self.failure != null) return;
        const code = @atomicLoad(u32, &endpoint.fault, .acquire);
        if (code == 0) return;
        self.recordFault(.{ .source = .irq, .kind = .device, .operation = .interrupt, .fatal = true, .code = code,
            .irq = endpoint.irq, .irq_raw = @atomicLoad(u32, &endpoint.last_raw, .acquire),
            .irq_mask = @atomicLoad(u32, &endpoint.last_mask, .acquire), .irq_received = @atomicLoad(u64, &endpoint.interrupts, .acquire),
            .irq_messages = @atomicLoad(u64, &endpoint.messages, .acquire) }) catch {};
    }
    pub fn activeChannel(self: *Owner) ?*exchange.Exchange {
        if (self.display_channel_active) |index| if (self.display_channels[index]) |*owner| return &owner.exchange;
        if (self.display_engine_active) if (self.display_engine_owner) |*owner| return &owner.exchange;
        if (self.fifo_active) |index| if (self.fifos[index].owner) |owner| return owner.channel();
        if (self.context_active) |index| if (self.contexts[index].owner) |owner| return &owner.exchange;
        if (self.native_active) |index| if (self.native_buffers[index].owner) |owner| return &owner.exchange;
        if (self.buffer_active) |index| if (self.buffers[index].owner) |owner| return &owner.exchange;
        if (self.outputs.channel()) |channel| return &channel.exchange;
        if (self.graph) |*graph| if (graph.channel()) |channel| return channel;
        return if (self.channel) |*channel| channel else null;
    }
    pub fn nativeObject(self: *Owner) ?display.Object {
        if (self.self_address != @intFromPtr(self) or self.failure != null or self.graph == null or
            self.display_upload_job != null or self.display_work != null or
            self.graph.?.self_address != @intFromPtr(&self.graph.?) or self.graph.?.state != .loaned or
            self.display_object == null or self.channel == null or self.activeChannel() != &self.channel.? or
            self.channel.?.session.state != .active) return null;
        return self.display_object;
    }
    pub fn nativeOutputs(self: *Owner) ?*const outputs.Snapshot {
        _ = self.now() catch return null;
        if (self.nativeObject() == null) return null;
        return self.outputs.snapshot();
    }
    pub fn nativeMemory(self: *Owner) ?*const inventory.Summary {
        _ = self.now() catch return null;
        return self.memory_inventory.snapshot();
    }
    pub fn nativeAddressSpace(self: *Owner) ?*const @import("gsp_vaspace.zig").Info {
        _ = self.now() catch return null;
        if (self.nativeObject() == null) return null;
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
        if (captured.chip == null or captured.chip.?.id != 0x176) return error.Unsupported;
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
        if (self.display_engine_active or self.copyBusy() or self.sequence.self_address != 0 or self.nativeObject() == null or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        var token = try self.channel.?.handoff(deadline);
        owner.beginDestroy(&token, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        self.display_engine_active = true;
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
        if (self.presentation != null) return error.Busy;
        const owner = try self.findDisplayChannel(handle);
        if (self.copyBusy() or self.sequence.self_address != 0 or self.nativeObject() == null or self.channel.?.phase != .idle or
            self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        var token = try self.channel.?.handoff(deadline);
        owner.beginDestroy(&token, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        self.display_channel_active = handle.slot;
    }
    /// Populate the retained instance before display channels can fetch it.
    /// Live-table replacement needs a later independent display-quiescence
    /// protocol; an idle RM exchange or a CE completion alone is insufficient.
    pub fn bindDisplayStorage(self: *Owner, handle: DisplayEngineHandle, kind: display_channel.wire.Kind, index: u32, source: BufferHandle) !u32 {
        if (kind == .immediate) return error.Unsupported; // WIMM has no RAMHT DMA contexts.
        const parent = try self.idleDisplayTable(handle);
        const config = parent.info() orelse return error.State;
        const slot = try display_channel.wire.slot(kind, index);
        if ((kind == .core and !config.core) or (kind == .window and (!config.window or config.hardware.windows & (@as(u32, 1) << @intCast(index)) == 0))) return error.Unsupported;
        const storage = try self.findNativeBuffer(source);
        const owner = try self.ensureDisplayResources(parent);
        return owner.bindNative(@intCast(slot), storage) catch |err| {
            if (err == error.Descriptor or err == error.Retained) self.stop(err);
            return err;
        };
    }
    pub fn createDisplayNotifier(self: *Owner, handle: DisplayEngineHandle, kind: display_channel.wire.Kind, index: u32) !u32 {
        if (kind == .immediate) return error.Unsupported; // Completion belongs to the coupled Window/Core.
        const parent = try self.idleDisplayTable(handle);
        const config = parent.info() orelse return error.State;
        const slot = try display_channel.wire.slot(kind, index);
        if ((kind == .core and !config.core) or (kind == .window and (!config.window or config.hardware.windows & (@as(u32, 1) << @intCast(index)) == 0))) return error.Unsupported;
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
    pub fn uploadDisplayTable(self: *Owner, root: DisplayEngineHandle, handle: ChannelHandle, deadline: u64) !void {
        const parent = try self.idleDisplayTable(root);
        const owner = self.display_resources_slot.owner orelse return error.State;
        if (!owner.valid() or !std.meta.eql(owner.binding.?, parent.binding) or owner.instance != &parent.instance_storage) return error.Stale;
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
    }
    /// Initial core methods and a notifier-backed UPDATE. This does not
    /// assert that a mode was adopted or that an image is visibly scanned.
    pub fn commitDisplayCore(self: *Owner, handle: DisplayChannelHandle, deadline: u64) !void {
        const core = try self.prepareDisplayCore(handle, deadline);
        self.display_work = .{ .core = core, .deadline = deadline };
    }
    fn prepareDisplayCore(self: *Owner, handle: DisplayChannelHandle, deadline: u64) !DisplaySubmission {
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
    /// Derive the candidate again from the actual retained Device capture and
    /// current coherent RM catalog; callers cannot submit arbitrary timings.
    pub fn bootDisplayPlan(self: *Owner, root_handle: DisplayEngineHandle, window: u32) !boot_mode.Plan {
        const root = try self.findDisplayEngine(root_handle);
        const info = root.info() orelse return error.State;
        const held = self.reservation orelse return error.State;
        _ = try held.binding(.metadata);
        const saved = held.display orelse return error.Stale;
        if (saved.original_boot == null or saved.scanout_original == null or saved.boot.held_generation == 0 or
            saved.chip == null or saved.chip.?.id != 0x176) return error.Stale;
        const plan = try boot_mode.capture(&saved.scanout_original.?, &saved.original_boot.?, window);
        if (!info.core or !info.window or plan.head >= info.hardware.heads or
            info.hardware.windows & (@as(u32, 1) << @intCast(window)) == 0) return error.Unsupported;
        // nativeObject deliberately excludes an outstanding display commit.
        // The submission gate must nevertheless revalidate its saved catalog
        // while that exact work owns the otherwise idle canonical RM channel.
        if (self.graph == null or self.graph.?.state != .loaned or self.display_object == null or self.channel == null or
            self.activeChannel() != &self.channel.? or self.channel.?.session.state != .active or self.failure != null) return error.Busy;
        const snapshot = self.outputs.snapshot() orelse return error.Busy;
        return boot_mode.bind(plan, snapshot, self.epoch, saved.boot.held_generation);
    }
    /// Carry the exact boot signal and primary position in one interlocked
    /// WIMM/Window/Core transaction. Common native adoption follows separately.
    pub fn commitBootDisplayImage(self: *Owner, core_handle: DisplayChannelHandle, window_handle: DisplayChannelHandle, image_handle: u32, deadline: u64) !void {
        const core = try self.findDisplayChannel(core_handle);
        const window = try self.findDisplayChannel(window_handle);
        if (core.parent != window.parent or window.config.kind != .window) return error.Stale;
        const root: DisplayEngineHandle = .{ .epoch = self.epoch, .root = core.parent.binding.root };
        const plan = try self.bootDisplayPlan(root, window.config.index);
        const link = try hdmi_link.derive(plan, self.display_object.?, self.outputs.snapshot().?);
        const resources = self.display_resources_slot.owner orelse return error.State;
        const image = resources.publishedImage(window_handle.slot, image_handle) orelse return error.State;
        if (image.width != plan.width or image.height != plan.height) return error.Descriptor;
        const slot = try display_channel.wire.slot(.immediate, window.config.index);
        const position = if (self.display_channels[slot]) |*value| value else return error.Unsupported;
        try self.commitPositionedDisplayImage(core_handle, window_handle,
            .{ .epoch = self.epoch, .handle = position.config.handle, .slot = @intCast(slot) }, image_handle, plan.head, .{}, deadline);
        self.display_work.?.core.config.signal = plan.signal;
        self.display_work.?.boot_mode = plan;
        self.display_work.?.link = .{ .plan = link };
    }
    pub fn commitPositionedDisplayImage(self: *Owner, core_handle: DisplayChannelHandle, window_handle: DisplayChannelHandle,
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
        if (self.presentation) |entry| {
            if (!self.presentationPrepared() or !std.meta.eql(entry.window, window_handle) or entry.surface.scanout.?.dma != image_handle)
                return error.Stale;
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
        core.config.route = route;
        self.display_work = .{ .core = core, .deadline = deadline,
            .window = .{ .handle = window_handle, .notifier = note,
                .config = .{ .notifier = note.handle, .windows = root.hardware.windows, .initialize = !owner.ring.initialized,
                    .kind = .window, .notifier_offset = offset, .scanout = image, .route = route } } };
    }
    pub fn displayImageStatus(self: *Owner, root: DisplayEngineHandle, window: u32) !?ActiveDisplayImage {
        _ = try self.findDisplayEngine(root);
        if (window >= self.display_images.len) return error.Bounds;
        return self.display_images[window];
    }
    /// Register the common queue consumer for a prepared private image.
    /// The display transition owner supplies its real CPU shadow; queued
    /// uploads are admitted only while that exact image is active.
    /// Registration alone does not adopt the boot framebuffer or change mode.
    pub fn registerDisplayPresentation(self: *Owner, handle: ChannelHandle, root: DisplayEngineHandle,
        window: DisplayChannelHandle, dma: u32, shadow: r4os.abi.GfxBufferHandle, deadline: u64) !r4os.abi.GfxBackendBinding
    {
        const fifo = try self.findChannel(handle);
        const window_owner = try self.findDisplayChannel(window);
        const engine = try self.findDisplayEngine(root);
        if (self.presentation != null or self.copy_backend != null or self.copyBusy() or self.nativeObject() == null or
            self.graph_closing or fifo.info() == null or !fifo.ring.idle() or window_owner.info() == null or window_owner.parent != engine or
            window_owner.config.kind != .window) return error.Busy;
        if (self.display_images[window_owner.config.index] != null) return error.Busy;
        const resources = self.display_resources_slot.owner orelse return error.State;
        const image = resources.publishedImage(window.slot, dma) orelse return error.State;
        const target = resources.publishedStorage(window.slot, dma) orelse return error.State;
        if (fifo.config.context.vaspace != self.nativeAddressSpace().?.handle) return error.Stale;
        try self.channel.?.guard(deadline);
        const queue = self.ctx.?.graphicsQueue() orelse return error.Api;
        const memory = self.ctx.?.memory() orelse return error.Api;
        if (queue.table.unregister_backend == 0) return error.Api;
        self.presentation = .{ .channel_handle = handle, .root = root, .window = window };
        const entry = &self.presentation.?;
        entry.surface.open(memory, shadow, target, image) catch |err| {
            if (entry.surface.failed) self.stop(err) else self.presentation = null;
            return err;
        };
        const result = queue.register(&.{ .adapter_id = self.adapter_id, .milestone = r4os.abi.gfx_queue_milestone_device_execution,
            .notify_callback = @intFromPtr(&notifyPresentation), .context = @intFromPtr(self) }, &entry.binding);
        if (result != r4os.abi.gfx_queue_ok and entry.binding.device_generation == 0) {
            if (!entry.surface.closeUnregistered()) { self.stop(error.Retained); return error.Retained; }
            self.presentation = null; return error.Queue;
        }
        entry.registered = true;
        self.copy_backend = .{ .queue = queue, .binding = entry.binding };
        if (result != r4os.abi.gfx_queue_ok or entry.binding.version != 1 or entry.binding.size < @sizeOf(r4os.abi.GfxBackendBinding) or
            entry.binding.adapter_id != self.adapter_id or entry.binding.milestone != r4os.abi.gfx_queue_milestone_device_execution or
            entry.binding.device_generation == 0 or entry.binding.reset_generation == 0) { self.stop(error.Descriptor); return error.Descriptor; }
        return entry.binding;
    }
    fn notifyPresentation(raw: usize) callconv(.c) i32 {
        if (raw == 0) return -1;
        const self: *Owner = @ptrFromInt(raw);
        if (self.self_address != raw or self.failure != null) return -1;
        const entry = if (self.presentation) |*value| value else return -1;
        if (!entry.registered or !entry.surface.valid()) return -1;
        // Already under the serialized DriverWork owner. Pacing owns waits.
        entry.pending = true;
        if (self.device.?.owner) |io| if (io.wake_work) |wake| wake(io.context);
        return 0;
    }
    fn presentationValid(self: *Owner) bool {
        if (!self.presentationPrepared()) return false;
        const entry = &self.presentation.?;
        const channel = self.findDisplayChannel(entry.window) catch return false;
        const active = self.display_images[channel.config.index] orelse return false;
        return entry.initial_point != 0 and std.meta.eql(active.image, entry.surface.scanout.?);
    }
    fn presentationPrepared(self: *Owner) bool {
        const entry = if (self.presentation) |*value| value else return false;
        if (!entry.registered or !entry.surface.valid() or self.copy_backend == null or
            !std.meta.eql(entry.binding, self.copy_backend.?.binding)) return false;
        const resources = self.display_resources_slot.owner orelse return false;
        const channel = self.findDisplayChannel(entry.window) catch return false;
        const root = self.findDisplayEngine(entry.root) catch return false;
        const value = entry.surface.scanout.?;
        return channel.info() != null and channel.parent == root and
            std.meta.eql(resources.publishedImage(entry.window.slot, value.dma), value) and
            resources.publishedStorage(entry.window.slot, value.dma) == entry.surface.target;
    }
    fn copyBusy(self: *const Owner) bool { return self.copy_job != null or self.display_upload_job != null or self.display_work != null or self.initial_image != null; }
    /// Called after the product owner populated and unmapped its CPU shadow
    /// from the same immutable capture used by common commit. This private
    /// operation does not invent a common queue fence.
    pub fn uploadInitialImage(self: *Owner, deadline: u64) !void {
        _ = try self.now();
        if (!self.presentationPrepared()) return error.State;
        const entry = &self.presentation.?;
        const fifo = try self.findChannel(entry.channel_handle);
        if (entry.initial_point != 0 or self.display_images[entry.window.slot - 1] != null or self.copyBusy() or
            self.graph_closing or !fifo.ring.idle() or self.fifo_active != null or self.context_active != null or
            self.native_active != null or self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or
            self.display_engine_active or self.display_channel_active != null or self.channel.?.phase != .idle or self.channel.?.in_lockdown)
            return error.Busy;
        try self.channel.?.guard(deadline);
        entry.initial_failure = null;
        self.initial_image = .{ .deadline = deadline };
    }
    pub fn initialImageStatus(self: *Owner) !InitialImageStatus {
        _ = try self.now();
        if (!self.presentationPrepared()) return error.State;
        return .{ .pending = self.initial_image != null, .completed = self.presentation.?.initial_point,
            .failure = self.presentation.?.initial_failure };
    }
    /// Discover the engine and create its RM group/share in this VA space.
    /// Channel children retain the context separately before using it.
    pub fn createExecutionContext(self: *Owner, rm_engine: u32, deadline: u64) !ContextHandle {
        return self.createContext(rm_engine, deadline) catch |err| { self.hostRejection(.context, err); return err; };
    }
    fn createContext(self: *Owner, rm_engine: u32, deadline: u64) !ContextHandle {
        _ = try self.now();
        if (self.graph_closing or self.fifo_active != null or self.context_active != null or self.native_active != null or self.buffer_active != null or self.sequence.self_address != 0 or self.outputs.active()) return error.Busy;
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        const subdevice = self.graph.?.base.plan.handles.subdevice;
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
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
        const value = execution_context.Owner.init(&token, self.graph.?.reservation, space, subdevice, rm_engine, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        const owner: *execution_context.Owner = @ptrFromInt(allocation.cpu_address);
        owner.* = value; slot.owner = owner; slot.serial = serial; self.buffer_serial = serial; self.context_active = index;
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
        if (self.copyBusy() or self.graph_closing or self.fifo_active != null or self.context_active != null or self.native_active != null or self.display_engine_active or self.display_channel_active != null) return error.Busy;
        const owner = try self.findContext(context);
        try owner.attachMethods(runqueue, try self.findNativeBuffer(buffer));
    }
    pub fn retireExecutionContext(self: *Owner, handle: ContextHandle, deadline: u64) !void {
        const owner = try self.findContext(handle);
        if (self.copyBusy() or self.fifo_active != null or self.context_active != null or self.native_active != null or self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or
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
        return self.createChannel(context_handle, runqueue, instance, userd, deadline);
    }
    /// Explicit native worker path; creating it does not publish renderer or
    /// display capabilities. The CE class is queried and allocated by RM.
    pub fn createCopyChannel(self: *Owner, context_handle: ContextHandle, runqueue: u8, instance: BufferHandle, deadline: u64) !ChannelHandle {
        return self.createChannel(context_handle, runqueue, instance, null, deadline);
    }
    fn createChannel(self: *Owner, context_handle: ContextHandle, runqueue: u8, instance: BufferHandle, userd: ?BufferHandle, deadline: u64) !ChannelHandle {
        return self.openChannel(context_handle, runqueue, instance, userd, deadline) catch |err| { self.hostRejection(.channel, err); return err; };
    }
    fn openChannel(self: *Owner, context_handle: ContextHandle, runqueue: u8, instance: BufferHandle, userd: ?BufferHandle, deadline: u64) !ChannelHandle {
        _ = try self.now();
        if (self.graph_closing or self.fifo_active != null or self.context_active != null or self.native_active != null or self.buffer_active != null or self.sequence.self_address != 0 or self.outputs.active()) return error.Busy;
        _ = self.nativeAddressSpace() orelse return error.State;
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
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
        owner.open(&token, &self.ctx.?, self.adapter_id, self.graph.?.reservation, parent, runqueue, inst, usr, deadline) catch |err| {
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
    pub fn retireExecutionChannel(self: *Owner, handle: ChannelHandle, deadline: u64, quiesced: bool) !void {
        if (self.presentation) |entry| if (std.meta.eql(entry.channel_handle, handle)) return error.Busy;
        const owner = try self.findChannel(handle);
        if (self.copyBusy()) return error.Busy;
        if (self.fifo_active != null or self.context_active != null or self.native_active != null or self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        var token = try self.channel.?.handoff(deadline);
        owner.beginDestroy(&token, deadline, quiesced) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; }; return err;
        };
        self.fifo_active = handle.slot;
    }
    fn freeChannelSlot(self: *Owner, index: usize) !void {
        const slot = &self.fifos[index]; const heap = slot.heap orelse return error.Api;
        if (heap.release(slot.allocation.handle) != r4os.abi.driver_heap_ok) return error.Retained;
        slot.* = .{};
    }
    /// Take the canonical job directly from the common queue. No caller can
    /// supply source addresses, completion points or edited job extents.
    pub fn beginCopyWork(self: *Owner, handle: ChannelHandle, binding: r4os.abi.GfxBackendBinding, deadline: u64) !bool {
        const fifo = try self.findChannel(handle);
        const value = fifo.info() orelse return error.State;
        if (!value.config.system_userd or !fifo.ring.idle() or self.copyBusy() or self.graph_closing or self.display_engine_active or self.display_channel_active != null or
            self.fifo_active != null or self.context_active != null or self.native_active != null or self.buffer_active != null or
            self.outputs.active() or self.sequence.self_address != 0 or self.channel.?.phase != .idle or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        const a = r4os.abi;
        if (binding.version != 1 or binding.size < @sizeOf(a.GfxBackendBinding) or binding.adapter_id != self.adapter_id or
            binding.milestone != a.gfx_queue_milestone_device_execution or binding.device_generation == 0 or binding.reset_generation == 0) return error.Descriptor;
        const queue = self.ctx.?.graphicsQueue() orelse return error.Api;
        const memory = self.ctx.?.memory() orelse return error.Api;
        if (queue.table.version != 1 or queue.table.size < @offsetOf(a.GfxDriverQueueApi, "unregister_backend") + 8 or
            queue.table.unregister_backend == 0) return error.Api;
        if (self.copy_backend) |*backend| {
            if (!std.meta.eql(backend.binding, binding) or !std.meta.eql(backend.queue.table, queue.table)) return error.Stale;
        }
        var job: a.GfxDriverJob = .{};
        const result = queue.take(&binding, &job);
        if (result != a.gfx_queue_ok and result != a.gfx_queue_error_busy and job.fence.timeline == 0) return error.Queue;
        if (self.copy_backend == null) self.copy_backend = .{ .queue = queue, .binding = binding };
        if (result == a.gfx_queue_error_busy and job.fence.timeline == 0) return false;
        self.copy_job = .{ .queue = queue, .memory = memory, .channel_handle = handle, .binding = binding,
            .job = job, .job_stamp = job, .deadline = deadline };
        if (result != a.gfx_queue_ok or job.version != 1 or job.size < @sizeOf(a.GfxDriverJob) or job.reserved0 != 0 or
            job.fence.adapter_id != binding.adapter_id or job.fence.timeline == 0 or job.fence.point == 0 or
            job.fence.device_generation != binding.device_generation or job.fence.reset_generation != binding.reset_generation) {
            self.stop(error.Descriptor); return error.Descriptor;
        }
        if ((job.operation != a.gfx_queue_operation_copy and job.operation != a.gfx_queue_operation_upload) or
            job.byte_length == 0 or job.byte_length > std.math.maxInt(u32)) { try self.finishCopy(a.gfx_queue_result_failed); return true; }
        if (job.operation == a.gfx_queue_operation_upload and job.target_buffer.id == 0) {
            if (!self.presentationValid() or !std.meta.eql(self.presentation.?.binding, binding) or
                self.presentation.?.channel_handle.slot != handle.slot or self.presentation.?.channel_handle.serial != handle.serial or
                !self.presentation.?.surface.matches(job)) { try self.finishCopy(a.gfx_queue_result_failed); return true; }
            self.copy_job.?.presentation = true;
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
        return true;
    }
    fn finishCopy(self: *Owner, result: u32) !void {
        self.retireCopy(result) catch |err| { self.stop(err); return err; };
    }
    fn retireCopy(self: *Owner, result: u32) !void {
        const work = &self.copy_job.?;
        const a = r4os.abi;
        if (work.queue.complete(&work.job.fence, result, 1) != a.gfx_queue_ok) return error.Retained;
        for (&work.references) |*reference| if (reference.reference.id != 0) {
            if (work.memory.bufferRelease(&reference.reference) != a.gfx_buffer_result_ok) return error.Retained;
            reference.* = .{};
        };
        if (result == a.gfx_queue_result_complete) self.copy_completed +|= 1;
        self.copy_job = null;
    }
    fn advanceCopy(self: *Owner, current: u64) !bool {
        const work = if (self.copy_job) |*value| value else return false;
        if (!std.meta.eql(work.job, work.job_stamp)) return error.Stale;
        const fifo = try self.findChannel(work.channel_handle);
        if (work.submitted) {
            if (try fifo.ring.poll() >= work.ticket.?.point) {
                try self.finishCopy(r4os.abi.gfx_queue_result_complete); return true;
            }
            if (current >= work.deadline) return error.Timeout; // Retain: a deadline is never quiescence.
            return false; // Continue processing GSP events while CE runs.
        }
        if (current >= work.deadline) {
            try self.recordFault(diagnostics.host(.submit, error.Timeout, false));
            try self.finishCopy(r4os.abi.gfx_queue_result_failed); return true;
        }
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return false;
        const resource_count: usize = if (work.presentation) 1 else 2;
        for (0..resource_count) |i| {
            if (work.addresses[i] != null) continue;
            const reference = work.references[i];
            for (&self.native_buffers) |*slot| if (slot.owner) |owner| {
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
            for (&self.buffers) |*slot| if (slot.owner) |owner| {
                if (owner.info()) |value| if (std.meta.eql(value.buffer, reference.buffer) and value.epoch == self.epoch and owner.space.handle == fifo.config.context.vaspace) {
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
        const transfer = self.copyTransfer() catch |err| {
            if (err == error.Bounds or err == error.Unsupported or err == error.Overflow) { try self.finishCopy(r4os.abi.gfx_queue_result_failed); return true; }
            return err;
        };
        work.transfer = transfer;
        work.ticket = fifo.prepareCopy(transfer) catch |err| {
            if (err == error.Bounds or err == error.Unsupported or err == error.Exhausted) { try self.finishCopy(r4os.abi.gfx_queue_result_failed); return true; }
            return err;
        };
        try self.device.?.submitCopy(fifo, work.ticket.?, work.deadline);
        work.submitted = true; return true;
    }
    pub fn copyTransfer(self: *Owner) !execution_fifo.copy.wire.Transfer {
        const work = if (self.copy_job) |*value| value else return error.State;
        if (!std.meta.eql(work.job, work.job_stamp)) return error.Stale;
        if (work.presentation) {
            if (!self.presentationValid() or !std.meta.eql(work.references[0].buffer, work.job.source_buffer) or
                work.references[0].flags != r4os.abi.gfx_buffer_reference_mapping_only or
                !std.meta.eql(work.channel_handle, self.presentation.?.channel_handle)) return error.Stale;
            const source = work.addresses[0] orelse return error.State;
            const fifo = try self.findChannel(work.channel_handle);
            var confirmed = false;
            for (&self.buffers) |*slot| if (slot.owner) |owner| if (owner.info()) |value| {
                if (std.meta.eql(value.buffer, work.references[0].buffer) and value.epoch == self.epoch and
                    value.address == source.address and value.logical_bytes == source.bytes and owner.space.handle == fifo.config.context.vaspace)
                    confirmed = true;
            };
            if (!confirmed) return error.Stale;
            return self.presentation.?.surface.transfer(work.job, source.address, source.bytes);
        }
        const job = &work.job;
        var addresses: [2]u64 = undefined;
        for (work.addresses, [_]u64{job.source_offset,job.target_offset}, 0..) |source, offset, i| {
            const value = source orelse return error.State;
            if (offset > value.bytes or job.byte_length > value.bytes - offset or value.address > std.math.maxInt(u64) - offset) {
                return error.Bounds;
            }
            addresses[i] = value.address + offset;
        }
        return .{ .source = addresses[0], .target = addresses[1], .bytes = job.byte_length };
    }
    fn advanceDisplayUpload(self: *Owner, current: u64) !bool {
        const work = if (self.display_upload_job) |*value| value else return false;
        const resources = self.display_resources_slot.owner orelse return error.State;
        const parent = if (self.display_engine_owner) |*value| value else return error.State;
        if (self.copy_job != null or parent.channels_started or !resources.valid() or !work.operation.valid() or
            work.operation.table != &resources.table or work.operation.target != &parent.instance_storage) return error.Stale;
        const fifo = try self.findChannel(work.channel_handle);
        if (work.operation.phase == .submitted) {
            const point = try fifo.ring.poll();
            if (point >= work.operation.ticket.?.point) {
                try work.operation.complete(point); self.display_upload_job = null; return true;
            }
            if (current >= work.operation.deadline) return error.Timeout;
            return false;
        }
        if (current >= work.operation.deadline) {
            try work.operation.cancel(); self.display_upload_job = null;
            try self.recordFault(diagnostics.host(.submit, error.Timeout, false)); return true;
        }
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return false;
        const transfer = try work.operation.transfer();
        work.operation.ticket = try fifo.prepareCopy(transfer);
        try self.device.?.submitCopy(fifo, work.operation.ticket.?, work.operation.deadline);
        try work.operation.submitted(work.operation.ticket.?); return true;
    }
    pub fn initialImageTransfer(self: *Owner) !execution_fifo.copy.wire.Transfer {
        if (!self.presentationPrepared()) return error.Stale;
        const entry = &self.presentation.?;
        const work = if (self.initial_image) |*value| value else return error.State;
        const source = try self.findBuffer(work.mapping orelse return error.State);
        const fifo = try self.findChannel(entry.channel_handle);
        if (entry.initial_point != 0 or work.operation.surface != &entry.surface or work.operation.source != source or
            source.space.handle != fifo.config.context.vaspace or work.operation.deadline != work.deadline or
            self.display_images[entry.window.slot - 1] != null) return error.Stale;
        return work.operation.transfer();
    }
    fn advanceInitialImage(self: *Owner, current: u64) !bool {
        const work = if (self.initial_image) |*value| value else return false;
        if (!self.presentationPrepared()) return error.Stale;
        const entry = &self.presentation.?;
        const fifo = try self.findChannel(entry.channel_handle);
        if (work.operation.submitted) {
            _ = try self.initialImageTransfer();
            const point = try fifo.ring.poll();
            if (point >= work.operation.ticket.?.point) {
                const completed = work.operation.ticket.?.point;
                try work.operation.complete(point);
                entry.initial_point = completed;
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
            for (&self.buffers, 0..) |*slot, index| if (slot.owner) |source| if (source.info()) |value| {
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
    pub fn validateDisplayLink(self: *Owner) !void {
        const work = if (self.display_work) |*value| value else return error.State;
        const link = if (work.link) |*value| value else return error.State;
        const window = if (work.window) |*value| value else return error.State;
        const position = if (work.position) |*value| value else return error.State;
        const core = try self.findDisplayChannel(work.core.handle);
        const actual = try self.findDisplayChannel(window.handle);
        if (actual.parent != core.parent or actual.config.kind != .window or work.boot_mode == null) return error.Stale;
        const expected = try self.bootDisplayPlan(.{ .epoch = self.epoch, .root = core.parent.binding.root }, actual.config.index);
        const planned = try hdmi_link.derive(expected, self.display_object.?, self.outputs.snapshot().?);
        if (!std.meta.eql(link.plan, planned) or !std.meta.eql(work.boot_mode.?, expected) or
            !std.meta.eql(work.core.config.signal, @as(?boot_mode.Signal, expected.signal)) or
            window.config.scanout == null or window.config.scanout.?.width != expected.width or window.config.scanout.?.height != expected.height or
            !std.meta.eql(work.core.config.route, @as(?display_channel.push.commands.Route, .{ .head = expected.head, .window = expected.window }))) return error.Stale;
        switch (link.phase) {
            .before_scanout => if (work.core.phase != .prepare or window.phase != .prepare or position.phase != .prepare) return error.State,
            .after_scanout, .complete => if (work.core.phase != .complete or window.phase != .complete or position.phase != .complete) return error.State,
            .scanout => {},
        }
    }
    fn advanceDisplayLink(self: *Owner, current: u64) !Progress {
        const work = &self.display_work.?;
        const link = &work.link.?;
        const channel = &self.channel.?;
        try self.validateDisplayLink();
        if (current >= work.deadline) return error.Timeout;
        if (!link.pending) {
            link.length = try hdmi_link.encode(link.plan, link.operation, &link.request);
            try channel.begin(hdmi_link.function, link.request[0..link.length], work.deadline);
            link.pending = true;
            return .progress;
        }
        if (try channel.poll(work.deadline)) |dispatch| {
            if (!dispatch.response) {
                try self.notification(channel, dispatch, current); return .progress;
            }
            const reply = try hdmi_link.decode(link.plan, link.operation, dispatch.record);
            link.last_status = reply.status; link.rpc_error = reply.rpc_error;
            try channel.complete(dispatch.ticket);
            if (reply.status != 0) {
                link.pending = false;
                self.rmFailure(.display_channel, link.plan.object.display, reply.status);
                return error.RmRejected;
            }
            try link.afterAck(dispatch.ticket.serial);
            return .progress;
        }
        return if (channel.phase == .waiting) .idle else .progress;
    }
    fn advanceDisplay(self: *Owner, current: u64) !bool {
        const work = if (self.display_work) |*value| value else return false;
        if (current >= work.deadline) return error.Timeout;
        if (work.link) |*link| {
            if (link.phase != .scanout and link.phase != .complete) return error.State;
            try self.validateDisplayLink();
        }
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
            if (window.phase != .complete) return progressed;
        }
        if (work.core.phase != .complete) return progressed;
        if (work.position) |*position| {
            progressed = try self.advanceDisplayPosition(position, work.deadline, current) or progressed;
            if (position.phase != .complete) return progressed;
        }
        if (work.link) |*link| if (link.phase == .scanout) {
            try link.scanoutComplete(); return true;
        };
        if (work.window) |window| {
            const route = window.config.route.?;
            var mode = work.boot_mode;
            var link: ?DisplayLink = if (work.link) |value| .{ .plan = value.plan, .acknowledged = value.acknowledged, .receipt = value.last_receipt } else null;
            var position: ?DisplayPosition = if (work.position) |value| .{ .handle = value.handle,
                .point = value.config.position.?, .sequence = value.ticket.?.point } else null;
            if (mode) |plan| {
                const core = try self.findDisplayChannel(work.core.handle);
                const expected = try self.bootDisplayPlan(.{ .epoch = self.epoch, .root = core.parent.binding.root }, route.window);
                if (!std.meta.eql(plan, expected) or !std.meta.eql(work.core.config.signal, @as(?boot_mode.Signal, expected.signal))) return error.Stale;
            } else if (self.display_images[route.window]) |prior| {
                if (prior.head == route.head and prior.image.width == window.config.scanout.?.width and prior.image.height == window.config.scanout.?.height) {
                    mode = prior.boot_mode;
                    link = prior.link;
                    if (position == null) position = prior.position;
                }
            }
            self.display_images[route.window] = .{ .image = window.config.scanout.?, .head = route.head,
                .core_point = work.core.ticket.?.point, .window_point = window.ticket.?.point, .boot_mode = mode, .position = position, .link = link };
        }
        self.display_work = null; return true;
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
            const result = if (work.config.kind == .core) try work.notifier.poll() else try work.notifier.pollWindow();
            if (result != null) {
                try owner.ring.finish(work.ticket.?.point); work.phase = .complete; return true;
            }
            if (current >= deadline) return error.Timeout;
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
        work.ticket = owner.ring.prepare(cursors.get, work.config) catch |err| {
            if (err == error.Busy) return false; return err;
        };
        const ticket = work.ticket.?;
        if (ticket.kind == .frame) {
            if (work.config.kind == .core) try work.notifier.arm(ticket.point, deadline)
            else try work.notifier.armWindow(ticket.point, deadline, work.config.notifier_offset);
        }
        try self.device.?.submitDisplay(owner, ticket, work.config, deadline);
        if (ticket.kind == .rewind) work.phase = .rewind else {
            try work.notifier.submitted(ticket.point, deadline); work.phase = .submitted;
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
    const MappingSource = union(enum) { queue: struct { fence: r4os.abi.GfxFence, which: u32 }, initial_image };
    fn mapBuffer(self: *Owner, request: MappingSource, deadline: u64) !BufferHandle {
        _ = try self.now();
        if (self.graph_closing or self.fifo_active != null or self.context_active != null or self.native_active != null or self.buffer_active != null or self.sequence.self_address != 0 or self.outputs.active()) return error.Busy;
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        const serial = try std.math.add(u64, self.buffer_serial, 1);
        const index: u16 = blk: {
            for (&self.buffers, 0..) |*slot, i| if (slot.allocation.handle == 0) break :blk @intCast(i);
            return error.Exhausted;
        };
        const heap = self.ctx.?.heap() orelse return error.Api;
        const memory = self.ctx.?.memory() orelse return error.Api;
        const slot = &self.buffers[index];
        slot.heap = heap;
        const result = heap.allocate(@sizeOf(buffer_mapping.Owner), @alignOf(buffer_mapping.Owner), &slot.allocation);
        const allocation = slot.allocation;
        if (result != r4os.abi.driver_heap_ok and allocation.handle == 0) return error.Memory;
        if (allocation.version != 1 or allocation.size < @sizeOf(r4os.abi.DriverHeapAllocation) or allocation.handle == 0 or
            allocation.cpu_address == 0 or allocation.cpu_address % @alignOf(buffer_mapping.Owner) != 0 or allocation.reserved != 0 or
            allocation.byte_length < @sizeOf(buffer_mapping.Owner) or allocation.alignment < @alignOf(buffer_mapping.Owner) or
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
                const queue = self.ctx.?.graphicsQueue() orelse return error.Api;
                break :blk queue.retainResource(&job.fence, job.which, source);
            },
            .initial_image => blk: {
                if (!self.presentationPrepared() or self.initial_image == null) return error.State;
                break :blk memory.bufferImport(&self.presentation.?.surface.shadow.reference, source);
            },
        };
        if (status != r4os.abi.gfx_buffer_result_ok and source.reference.id == 0 and source.buffer.id == 0) return error.Resource;
        // Invalid returned ownership must remain inspectable; never drop an
        // unvalidated handle on an allocation error.
        if (source.version != 1 or source.size < @sizeOf(r4os.abi.GfxBufferReference) or source.reserved0 != 0 or
            source.reference.id == 0 or source.reference.generation == 0 or source.reference.reserved0 != 0 or
            source.buffer.id == 0 or source.buffer.generation == 0 or source.buffer.reserved0 != 0 or
            source.flags != @as(u32, if (request == .queue) r4os.abi.gfx_buffer_reference_mapping_only else 0)) {
            self.stop(error.Descriptor); return error.Descriptor;
        }
        errdefer {
            if (memory.bufferRelease(&source.reference) == r4os.abi.gfx_buffer_result_ok) source.* = .{} else self.stop(error.Retained);
        }
        if (status != r4os.abi.gfx_buffer_result_ok) return error.Resource;
        if (request == .initial_image and !std.meta.eql(source.buffer, self.presentation.?.surface.shadow.buffer)) return error.Stale;
        var token = try self.channel.?.handoff(deadline);
        const value = buffer_mapping.Owner.init(&token, &self.ctx.?, self.adapter_id, space, self.graph.?.reservation, source.*, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| {
                self.stop(restore);
                return restore;
            };
            return err;
        };
        const owner: *buffer_mapping.Owner = @ptrFromInt(allocation.cpu_address);
        owner.* = value;
        slot.owner = owner;
        source.* = .{};
        slot.serial = serial;
        self.buffer_serial = serial;
        self.buffer_active = index;
        return .{ .epoch = self.epoch, .serial = serial, .slot = index };
    }
    fn findBuffer(self: *Owner, handle: BufferHandle) !*buffer_mapping.Owner {
        _ = try self.now();
        if (handle.epoch != self.epoch or handle.slot >= self.buffers.len or handle.serial == 0 or
            self.buffers[handle.slot].serial != handle.serial) return error.Stale;
        return self.buffers[handle.slot].owner orelse return error.Stale;
    }
    pub fn bufferStatus(self: *Owner, handle: BufferHandle) !BufferStatus {
        const owner = try self.findBuffer(handle);
        return .{ .state = owner.state, .info = owner.info(), .rejected = owner.rejected, .host_rejected = owner.host_rejected };
    }
    pub fn retireBuffer(self: *Owner, handle: BufferHandle, deadline: u64, quiesced: bool) !void {
        const owner = try self.findBuffer(handle);
        if (self.copyBusy()) return error.Busy;
        if (!quiesced or self.fifo_active != null or self.context_active != null or self.native_active != null or self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or
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
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        return self.allocateNativePlan(try vram.surface.raw(self.adapter_id, space, bytes), deadline);
    }
    pub fn allocateNativeSurface(self: *Owner, request: vram.surface.Request, deadline: u64) !BufferHandle {
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        const caps = self.nativeMemoryCapabilities() orelse return error.State;
        return self.allocateNativePlan(try vram.surface.create(self.adapter_id, space, caps, request), deadline);
    }
    /// Own scanout requires a verified contiguous physical extent in the
    /// display DMA context, while retaining the common native BO descriptor.
    pub fn allocateDisplaySurface(self: *Owner, request: vram.surface.Request, deadline: u64) !BufferHandle {
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        const caps = self.nativeMemoryCapabilities() orelse return error.State;
        const summary = self.nativeMemory() orelse return error.State;
        const plan = try vram.surface.create(self.adapter_id, space, caps, request);
        _ = try display_resources.image.create(plan, 1, 1);
        const policy: vram.storage.Policy = .{ .capabilities = caps, .physical_bytes = @min(summary.physical_bytes, summary.reported_bytes), .role = .scanout };
        try policy.validate(space, plan.allocation_bytes);
        return self.allocateNativePlanStorage(plan, policy, deadline);
    }
    /// Private instance/USERD/method backing: RM must guarantee initial
    /// clearing and confirm a contiguous extent. Ordinary BOs stay opaque.
    pub fn allocateNativeStorage(self: *Owner, bytes: u64, deadline: u64) !BufferHandle {
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        const caps = self.nativeMemoryCapabilities() orelse return error.State;
        const memory_summary = self.nativeMemory() orelse return error.State;
        const policy: vram.storage.Policy = .{ .capabilities = caps, .physical_bytes = @min(memory_summary.physical_bytes, memory_summary.reported_bytes) };
        const plan = try vram.surface.raw(self.adapter_id, space, bytes);
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
        _ = try self.now();
        if (self.graph_closing or self.fifo_active != null or self.context_active != null or self.native_active != null or self.buffer_active != null or self.sequence.self_address != 0 or self.outputs.active()) return error.Busy;
        const space = (self.nativeAddressSpace() orelse return error.State).*;
        if (self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return error.Busy;
        try self.channel.?.guard(deadline);
        const serial = try std.math.add(u64, self.buffer_serial, 1);
        const index: u16 = blk: {
            for (&self.native_buffers, 0..) |*slot, i| if (slot.allocation.handle == 0) break :blk @intCast(i);
            return error.Exhausted;
        };
        const heap = self.ctx.?.heap() orelse return error.Api;
        const slot = &self.native_buffers[index];
        slot.heap = heap;
        const result = heap.allocate(@sizeOf(vram.Owner), @alignOf(vram.Owner), &slot.allocation);
        const allocation = slot.allocation;
        if (result != r4os.abi.driver_heap_ok and allocation.handle == 0) return error.Memory;
        if (allocation.version != 1 or allocation.size < @sizeOf(r4os.abi.DriverHeapAllocation) or allocation.handle == 0 or
            allocation.cpu_address == 0 or allocation.cpu_address % @alignOf(vram.Owner) != 0 or allocation.reserved != 0 or
            allocation.byte_length < @sizeOf(vram.Owner) or allocation.alignment < @alignOf(vram.Owner) or
            allocation.cpu_address > std.math.maxInt(u64) - allocation.byte_length) {
            self.stop(error.Descriptor); return error.Descriptor;
        }
        errdefer if (heap.release(allocation.handle) == r4os.abi.driver_heap_ok) { slot.* = .{}; } else self.stop(error.Retained);
        if (result != r4os.abi.driver_heap_ok) return error.Memory;
        var token = try self.channel.?.handoff(deadline);
        const value = vram.Owner.initStorage(&token, &self.ctx.?, self.adapter_id, space, self.graph.?.reservation, plan, policy, deadline) catch |err| {
            self.channel = exchange.Exchange.init(&token, deadline) catch |restore| { self.stop(restore); return restore; };
            return err;
        };
        const owner: *vram.Owner = @ptrFromInt(allocation.cpu_address);
        owner.* = value; slot.owner = owner; slot.serial = serial;
        self.buffer_serial = serial; self.native_active = index;
        return .{ .epoch = self.epoch, .serial = serial, .slot = index };
    }
    fn findNativeBuffer(self: *Owner, handle: BufferHandle) !*vram.Owner {
        _ = try self.now();
        if (handle.epoch != self.epoch or handle.slot >= self.native_buffers.len or handle.serial == 0 or
            self.native_buffers[handle.slot].serial != handle.serial) return error.Stale;
        return self.native_buffers[handle.slot].owner orelse return error.Stale;
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
        const slot = &self.native_buffers[index];
        const heap = slot.heap orelse return error.Api;
        if (heap.release(slot.allocation.handle) != r4os.abi.driver_heap_ok) return error.Retained;
        slot.* = .{};
    }
    fn collectNativeBuffer(self: *Owner, deadline: u64) !bool {
        if (self.fifo_active != null or self.context_active != null or self.native_active != null or self.buffer_active != null or self.outputs.active() or self.sequence.self_address != 0 or
            self.channel.?.phase != .idle or self.channel.?.pending != null or self.channel.?.in_lockdown) return false;
        const memory = blk: {
            for (&self.native_buffers) |*slot| if (slot.owner) |owner| { if (owner.closing and owner.common_live) break :blk owner.memory; };
            return false;
        };
        var ticket: r4os.abi.GfxOwnedBufferRelease = .{};
        const result = memory.bufferTakeRelease(self.adapter_id, self.epoch, &ticket);
        if (result == r4os.abi.gfx_buffer_error_busy) return false;
        if (result != r4os.abi.gfx_buffer_result_ok) return error.Retained;
        for (&self.native_buffers, 0..) |*slot, index| if (slot.owner) |owner| {
            if (!owner.accepts(ticket)) continue;
            var token = try self.channel.?.handoff(deadline);
            try owner.beginDestroy(&token, ticket, deadline);
            self.native_active = @intCast(index); return true;
        };
        return error.Descriptor; // Claimed unknown identity remains held.
    }
    /// Requires all engine users independently quiesced. Each child mapping
    /// is drained before graph.beginDestroy may send any parent/event free.
    pub fn beginDestroyGraph(self: *Owner, deadline: u64, quiesced: bool) !void {
        _ = try self.now();
        if (self.copyBusy() or self.display_engine_owner != null) return error.Busy;
        if (!quiesced or self.graph_closing or self.fifo_active != null or self.context_active != null or self.native_active != null or self.buffer_active != null or self.outputs.active() or
            self.sequence.self_address != 0 or self.nativeObject() == null or self.channel.?.phase != .idle) return error.Busy;
        try self.channel.?.guard(deadline);
        for (&self.native_buffers, 0..) |*slot, index| if (slot.owner != null) {
            try self.releaseNativeBuffer(.{ .epoch = self.epoch, .serial = slot.serial, .slot = @intCast(index) });
        };
        self.graph_closing = true;
        self.close_deadline = deadline;
    }
    pub fn takeDisplayChanges(self: *Owner) !subscriptions.Changes {
        const current = try self.now();
        if (self.nativeObject() == null) return error.State;
        return self.graph.?.takeChanges(try std.math.add(u64, current, std.time.ns_per_s));
    }
    fn advance(self: *Owner) !Progress {
        const current = try self.now();
        const channel = self.activeChannel() orelse return error.State;
        self.snapshot.polls +|= 1;
        self.snapshot.last_poll_ns = current;
        if (self.sequence.self_address != 0) {
            if (try self.sequence.step() == .complete) {
                if (!self.sequence.close()) return error.Retained;
                self.snapshot.sequencers +|= 1;
                self.snapshot.events +|= 1;
                self.snapshot.last_event_ns = current;
            }
            return .progress;
        }
        if (self.display_channel_active) |index| {
            const owner = if (self.display_channels[index]) |*value| value else return error.State;
            if (owner.state == .ready or owner.state == .closed) {
                if (owner.state == .ready) try self.rejection(.display_channel, owner.config.handle, owner.rejected, owner.host_rejected);
                if (owner.info()) |value| self.log("NVIDIA gsp-display-channel: handle={x} class={x} index={d} physical={x} bytes=4096 methods=empty",
                    .{value.config.handle,display_channel.wire.class(value.config.kind),value.config.index,value.config.physical});
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
            if (owner.poll() catch |err| { self.rmFailure(.display_channel, owner.config.handle, owner.last_status); return err; }) |dispatch| {
                try self.notification(&owner.exchange, dispatch, current); return .progress;
            }
            return if (owner.exchange.phase == .waiting) .idle else .progress;
        }
        if (self.display_engine_active) {
            const owner = if (self.display_engine_owner) |*value| value else return error.State;
            if (owner.state == .ready or owner.state == .closed) {
                if (owner.state == .ready) try self.rejection(.display_engine, owner.binding.root, owner.rejected, null);
                if (owner.info()) |value| self.log("NVIDIA gsp-display-engine: root={x} class=c670 heads={d} windows={x} channels={d} instance={} scanout=unbound",
                    .{value.binding.root,value.hardware.heads,value.hardware.windows,value.hardware.channels,value.instance_bound});
                const deadline = owner.deadline; var token = try owner.handoff();
                const finished = owner.state == .finished;
                self.channel = try exchange.Exchange.init(&token, deadline);
                if (finished) self.display_engine_owner = null;
                self.display_engine_active = false; return .progress;
            }
            if (owner.poll() catch |err| { self.rmFailure(.display_engine, owner.binding.root, owner.last_status); return err; }) |dispatch| {
                try self.notification(&owner.exchange, dispatch, current); return .progress;
            }
            return if (owner.exchange.phase == .waiting) .idle else .progress;
        }
        if (self.fifo_active) |index| {
            const owner = self.fifos[index].owner orelse return error.State;
            if (owner.state == .ready or owner.state == .closed) {
                if (owner.state == .ready) try self.rejection(.channel, owner.config.handle, owner.rejected, owner.host_rejected);
                if (owner.info()) |fifo_info| self.log("NVIDIA gsp-fifo: channel={x} cid={d} engine={x} scheduled=yes copy-class={x}",
                    .{fifo_info.config.handle,fifo_info.cid,fifo_info.config.rm_engine,fifo_info.config.copy_class});
                const deadline = owner.deadline; var token = try owner.handoff();
                self.channel = try exchange.Exchange.init(&token, deadline);
                if (owner.state == .finished) try self.freeChannelSlot(index);
                self.fifo_active = null; return .progress;
            }
            if (owner.poll() catch |err| { self.rmFailure(.channel, owner.config.handle, owner.last_status); return err; }) |dispatch| {
                try self.notification(owner.channel().?, dispatch, current); return .progress;
            }
            return if (owner.channel().?.phase == .waiting) .idle else .progress;
        }
        if (self.context_active) |index| {
            const owner = self.contexts[index].owner orelse return error.State;
            if (owner.state == .ready or owner.state == .closed) {
                if (owner.state == .ready) try self.rejection(.context, owner.binding.group, owner.rejected, null);
                if (owner.info()) |info| self.log("NVIDIA gsp-context: group={x} share={x} engine={x} runlist={d} fifo=unallocated",
                    .{info.binding.group, info.binding.share, info.nv_engine, info.engine.data[3]});
                const deadline = owner.deadline; var token = try owner.handoff();
                self.channel = try exchange.Exchange.init(&token, deadline);
                if (owner.state == .finished) try self.freeContextSlot(index);
                self.context_active = null; return .progress;
            }
            if (owner.poll() catch |err| { self.rmFailure(.context, owner.binding.group, owner.last_status); return err; }) |dispatch| {
                try self.notification(&owner.exchange, dispatch, current); return .progress;
            }
            return if (owner.exchange.phase == .waiting) .idle else .progress;
        }
        if (self.native_active) |index| {
            const owner = self.native_buffers[index].owner orelse return error.State;
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
            if (owner.poll() catch |err| { self.rmFailure(.native_buffer, owner.binding.memory, owner.last_status); return err; }) |dispatch| {
                try self.notification(&owner.exchange, dispatch, current);
                return .progress;
            }
            return if (owner.exchange.phase == .waiting) .idle else .progress;
        }
        if (self.buffer_active) |index| {
            const slot = &self.buffers[index];
            const owner = slot.owner orelse return error.State;
            if (owner.state == .ready or owner.state == .closed) {
                if (owner.state == .ready) try self.rejection(.mapping, owner.reservation.object(0) catch 0, owner.rejected, owner.host_rejected);
                var token = try owner.handoff(owner.deadline);
                self.channel = try exchange.Exchange.init(&token, owner.deadline);
                if (owner.state == .finished) {
                    const heap = slot.heap orelse return error.Api;
                    if (heap.release(slot.allocation.handle) != r4os.abi.driver_heap_ok) return error.Retained;
                    slot.* = .{};
                }
                self.buffer_active = null;
                return .progress;
            }
            if (owner.poll() catch |err| { self.rmFailure(.mapping, owner.reservation.object(0) catch 0, owner.last_status); return err; }) |dispatch| {
                try self.notification(&owner.exchange, dispatch, current);
                return .progress;
            }
            return if (owner.exchange.phase == .waiting) .idle else .progress;
        }
        // The display transaction owns these setter replies. Do not let the
        // generic graph/query dispatcher consume or acknowledge them.
        if (self.display_work) |*work| if (work.link) |*link| {
            if (link.phase == .before_scanout or link.phase == .after_scanout) return self.advanceDisplayLink(current);
        };
        // Drain an already observable GSP fault before publishing CE success.
        // Active RPC owners above already receive before sending their work.
        if (self.copyBusy() and channel.phase == .idle) {
            const end = channel.deadline orelse try std.math.add(u64, current, std.time.ns_per_s);
            if (try channel.poll(end)) |dispatch| {
                try self.notification(channel, dispatch, current); return .progress;
            }
        }
        if (try self.advanceDisplayUpload(current)) return .progress;
        if (try self.advanceInitialImage(current)) return .progress;
        if (try self.advanceDisplay(current)) return .progress;
        if (try self.advanceCopy(current)) return .progress;
        if (self.presentation) |*entry| if (entry.pending and !self.copyBusy() and self.presentationValid()) {
            const taken: ?bool = self.beginCopyWork(entry.channel_handle, entry.binding, try std.math.add(u64, current, 3 * std.time.ns_per_s)) catch |err| blk: {
                if (err == error.Busy) break :blk null; return err;
            };
            if (taken) |claimed| {
                if (claimed) return .progress;
                entry.pending = false;
            }
            // A pending frame must not starve an output query or other
            // runtime owner that currently prevents taking the queue job.
        };
        if (self.nativeObject() != null and try self.collectNativeBuffer(if (self.graph_closing) self.close_deadline else try std.math.add(u64, current, 5 * std.time.ns_per_s))) return .progress;
        if (self.graph_closing and self.graph.?.state == .loaned) graph_close: {
            try channel.guard(self.close_deadline);
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
            for (&self.buffers, 0..) |*slot, index| if (slot.owner != null) {
                try self.retireBuffer(.{ .epoch = self.epoch, .serial = slot.serial, .slot = @intCast(index) }, self.close_deadline, true);
                return .progress;
            };
            for (&self.native_buffers) |*slot| if (slot.owner != null) break :graph_close;
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
                self.output_next_ns = try std.math.add(u64, current, std.time.ns_per_s);
                self.log("NVIDIA gsp-outputs: generation={d} inventory={s} routes={d} receivers={d} native-output=unavailable",
                    .{self.output_generation, if (!self.outputs.data.coherent) @as([]const u8, "obsolete") else if (self.outputs.data.topology.rejected != null) "query-rejected" else "complete",
                        self.outputs.data.topology.count, self.outputs.data.count});
                if (self.outputs.data.final_rejection orelse self.outputs.data.topology.rejected) |rejected|
                    self.log("NVIDIA gsp-outputs: rejected command={x} rpc={?} rm={?}", .{@intFromEnum(rejected.command), rejected.rpc, rejected.control});
                if (self.outputs.data.coherent) {
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
                if (capture.source == .aux or capture.aux_rpc_status != null or capture.aux_control_status != null or capture.aux_reply != null)
                    self.log("NVIDIA gsp-aux: generation={d} display={x} dpcd={d} retries={d} rpc={?} rm={?} reply={?}",
                        .{self.output_generation, capture.display_id, capture.aux_caps_bytes, capture.aux_retries,
                            capture.aux_rpc_status, capture.aux_control_status,
                            if (capture.aux_reply) |reply| @as(?u32, @intFromEnum(reply)) else null});
            }
            if (self.outputs.refresh) |*refresh| if (refresh.waiting()) return .idle;
            return if ((self.activeChannel() orelse return error.State).phase == .waiting) .idle else .progress;
        }
        if (self.graph) |*graph| {
            switch (graph.state) {
                .ready => {
                    var loan = try graph.loan(graph.deadline);
                    self.channel = try exchange.Exchange.init(&loan.runtime, graph.deadline);
                    self.display_object = loan.object;
                    self.log("NVIDIA gsp-rm: objects=ready client={x} device={x} subdevice={x} display={x} events=HPD,DP native-output=unavailable",
                        .{graph.base.plan.handles.client, graph.base.plan.handles.device, graph.base.plan.handles.subdevice, loan.object.display});
                    if (self.nativeAddressSpace()) |info|
                        self.log("NVIDIA gsp-vaspace: handle={x} base={x} bytes={x} big-page={d} page-tables=RM app-mappings=none",
                            .{info.handle, info.base, info.bytes, info.big_page_bytes})
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
                    return if (self.graph_closing) error.RmClosed else error.RmRejected; // Object frees do not stop GPU DMA.
                },
                .base_creating, .i2c_creating, .vaspace_creating, .control_creating, .events_creating, .events_destroying, .control_destroying, .vaspace_destroying, .i2c_destroying, .base_destroying => {
                    if (try graph.poll()) |dispatch| {
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
            self.graph = try rm.Owner.init(&token, std.math.maxInt(u32), "", end);
            self.graph.?.control_context = self.ctx;
            self.graph.?.control_adapter = self.adapter_id;
            self.log("NVIDIA gsp-rm: creating client={x} deadline-ns={d}", .{self.graph.?.reservation.client, end});
            return .progress;
        }
        if (!self.graph_closing and self.graph != null and self.graph.?.state == .loaned and channel.phase == .idle and !channel.in_lockdown and
            !self.copyBusy() and (self.outputs.state == .detached or (self.output_refresh and current >= self.output_next_ns))) {
            const end = try std.math.add(u64, current, 10 * std.time.ns_per_s);
            self.output_generation = try std.math.add(u64, self.output_generation, 1);
            var token = try channel.handoff(end);
            try self.graph.?.reclaim(&token, end);
            try self.outputs.begin(&self.graph.?, self.output_generation, end);
            self.output_refresh = false;
            self.log("NVIDIA gsp-outputs: acquiring generation={d} deadline-ns={d}", .{self.output_generation, end});
            return .progress;
        }
        // No busy wait or raw-log dump on every empty queue. One ring per
        // second bounds DMA copying and output, even under continual logging.
        if (current >= self.next_log and self.reader.?.enabled) {
            self.next_log = current +| std.time.ns_per_s;
            try self.captureLog(deadline);
        }
        return .idle;
    }
    fn logMemory(self: *Owner) void {
        const data = self.nativeMemory() orelse return;
        self.log("NVIDIA gsp-memory: epoch={d} physical={d} reported={d} regions={d} holes={d} rm-budget={d} retained={d} screened={d} allocation=none",
            .{data.epoch, data.physical_bytes, data.reported_bytes, data.region_count, data.region_holes,
                data.speculative_reserved, data.retained_bytes, data.screened_bytes});
        self.log("NVIDIA gsp-memory: union={d} surface-extents={d} table-pages={d} instance={any} payload-extents={d} firmware-layout-matches={any}",
            .{data.retained_count, data.surface_extents, data.table_pages, data.instance_active, data.payload_extents, data.firmware_layout_matches});
        for (data.windows) |bar|
            self.log("NVIDIA gsp-aperture: pci-bar={d} base={x} bytes={d} status={s} prefetch={any} rebar-present={any} resize=no",
                .{bar.pci_index, bar.base, bar.bytes, @tagName(bar.status), bar.prefetchable, data.rebar_present});
        for (self.memory_inventory.regions[0..data.region_count], 0..) |*region, index|
            self.log("NVIDIA gsp-region: index={d} base={x} bytes={d} rm-budget={d} protected={any} iso={any} compressed={any} performance={d}",
                .{index, region.base, region.bytes, region.reserved, region.protected, region.iso, region.compressed, region.performance});
    }
    fn notification(self: *Owner, channel: *exchange.Exchange, dispatch: exchange.Dispatch, current: u64) !void {
        if (dispatch.response) return error.Unexpected;
        const source = self.outputs.channel();
        if (source != null and &source.?.exchange != channel) return error.Binding;
        if (dispatch.record.rpc.function != @intFromEnum(boot.Kind.libos_print)) try self.outputs.invalidate();
        if (dispatch.record.rpc.function == @intFromEnum(boot.Kind.cpu_sequencer)) {
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
                self.output_refresh = true; // Coalesced; no new scan until current receipts drain.
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
    fn logBytes(self: *Owner, kind: []const u8, source: u32, bytes: []const u8) void {
        var escaped: [160]u8 = undefined;
        const count = @min(bytes.len, escaped.len);
        for (bytes[0..count], escaped[0..count]) |byte, *out| out.* = if (byte >= 32 and byte < 127) byte else '.';
        self.log("NVIDIA gsp-runtime: {s} source={d} bytes={d} text={s}", .{kind, source, bytes.len, escaped[0..count]});
    }
};
