//! Copied worker-side observations; no MMIO, allocation or recovery authority.
//! An acknowledged image is historical evidence, not proof of a live signal.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;

pub const Image = struct {
    dma: u32 = 0,
    head: u32 = 0,
    window: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    format: u32 = 0,
    mode: u32 = 0,
    sor: u32 = 0,
    clock_word: u32 = 0,
    refresh_micro_hz: u64 = 0,
    core_point: u64 = 0,
    window_point: u64 = 0,
    mode_receipt: u64 = 0,
    link_receipt: u64 = 0,
};
pub const Report = struct {
    sequence: u64 = 0,
    ticket: u64 = 0,
    operation_sequence: u64 = 0,
    operation: u32 = 0,
    output: a.GfxOutputId = .{},
    epoch: u64 = 0,
    hold: u64 = 0,
    requested: a.GfxOutputMode = .{},
    before: Image = .{},
    after: Image = .{},
    selected: u32 = 0,
    pending: u32 = 0,
    initial_read_lease: u64 = 0,
    shadow_imports: u32 = 0,
    native_owners: u32 = 0,
    phase: []const u8 = "none",
    failure: ?anyerror = null,
    outcome: u32 = 0,
    quiesced: u32 = 0,
    error_code: i32 = 0,
    common_status: i32 = 0,
    started_ns: u64 = 0,
    observed_ns: u64 = 0,
    observed_valid: bool = false,
    deadline_ns: u64 = 0,

    pub fn begin(self: *Report, product: anytype, job: a.GfxDriverModeJob) void {
        self.* = .{ .sequence = self.sequence +| 1, .ticket = job.ticket, .operation_sequence = job.sequence,
            .operation = job.operation, .output = job.assignment.output, .epoch = product.running.?.epoch,
            .hold = product.captured.?.boot.held_generation, .requested = job.mode,
            .before = acknowledged(product), .started_ns = product.last_clock, .deadline_ns = job.deadline_ns };
    }
    pub fn failed(self: *Report, phase: []const u8, err: anyerror) void {
        self.phase = phase;
        self.failure = err;
    }
    pub fn finish(self: *Report, product: anytype, phase: []const u8, receipt: a.GfxDriverModeCompletion, status: i32) void {
        if (self.failure == null) self.phase = phase;
        self.after = acknowledged(product);
        // Runtime failure can precede the product's next step. Its cached
        // clock would then misleadingly place a timeout before the deadline.
        self.observed_ns = 0; self.observed_valid = false;
        if (product.ctx.?.resources()) |clock| {
            const now = clock.nowNs();
            if (now != 0 and now != std.math.maxInt(u64) and now >= product.last_clock) {
                self.observed_ns = now; self.observed_valid = true;
            }
        }
        self.outcome = receipt.outcome; self.quiesced = receipt.quiesced; self.error_code = receipt.error_code; self.common_status = status;
        self.pending = 0; self.initial_read_lease = 0; self.shadow_imports = 0; self.native_owners = 0; self.selected = 0;
        const run = product.running.?;
        if (run.initial_image) |*work| { self.pending |= 1; self.initial_read_lease = work.operation.gpu.lease.id; }
        if (run.display_work != null) self.pending |= 2;
        if (run.display_upload_job != null) self.pending |= 4;
        if (run.copy_job != null) self.pending |= 8;
        if (run.native_active != null) self.pending |= 16;
        if (run.display_flip != null) self.pending |= 32;
        if (run.frame_ready != null) self.pending |= 64;
        if (run.frame_setup != null) self.pending |= 128;
        for (&run.native_buffers) |*slot| if (slot.owner != null) { self.native_owners += 1; };
        for (&run.presentation_slots) |*slot| if (slot.*) |*entry| {
            if (entry.surface.shadow.reference.id != 0) self.shadow_imports += 1;
        };
        if (run.presentation) |entry| if (entry.surface.scanout) |image| { self.selected = image.dma; };
        const ctx = &product.ctx.?;
        write(ctx, "NVIDIA mode-result: ticket={d} seq={d} op={d} phase={s} reason={s} outcome={d} quiesced={d} error={d} api={d}",
            .{self.ticket,self.operation_sequence,self.operation,self.phase,if(self.failure)|err|@errorName(err) else "none",self.outcome,self.quiesced,self.error_code,self.common_status});
        write(ctx, "NVIDIA mode-route: ticket={d} adapter={x} connector={x} device={d} connection={d} epoch={d} boot-hold={d}",
            .{self.ticket,self.output.adapter_id,self.output.connector_id,self.output.device_generation,self.output.connection_generation,self.epoch,self.hold});
        write(ctx, "NVIDIA mode-request: ticket={d} seq={d} mode={d} size={d}x{d} clock-hz={d} refresh-mHz={d} started={d} deadline={d} observed={d} observed-valid={}",
            .{self.ticket,self.operation_sequence,self.requested.mode_id,self.requested.width,self.requested.height,self.requested.pixel_clock_hz,
                self.requested.refresh_millihz,self.started_ns,self.deadline_ns,self.observed_ns,self.observed_valid});
        self.imageLog(ctx, "before", self.before);
        self.imageLog(ctx, "after", self.after);
        write(ctx, "NVIDIA mode-held: ticket={d} seq={d} selected={d} pending-mask={x} initial-read-lease={d} shadows={d} native-owners={d}",
            .{self.ticket,self.operation_sequence,self.selected,self.pending,self.initial_read_lease,self.shadow_imports,self.native_owners});
    }
    fn imageLog(self: *const Report, ctx: *const r4os.r4dev.DriverContext, label: []const u8, value: Image) void {
        write(ctx, "NVIDIA mode-ack-{s}: ticket={d} seq={d} dma={d} size={d}x{d} pitch={d} format={x} head={d} window={d} sor={d} mode={d}",
            .{label,self.ticket,self.operation_sequence,value.dma,value.width,value.height,value.pitch,value.format,value.head,value.window,value.sor,value.mode});
        write(ctx, "NVIDIA mode-proof-{s}: ticket={d} seq={d} clock-word={x} refresh-uHz={d} core={d} window={d} mode-receipt={d} link-receipt={d}",
            .{label,self.ticket,self.operation_sequence,value.clock_word,value.refresh_micro_hz,value.core_point,value.window_point,value.mode_receipt,value.link_receipt});
    }
};
fn acknowledged(product: anytype) Image {
    const run = product.running orelse return .{};
    const mode = product.mode orelse return .{};
    if (mode.window >= run.display_images.len) return .{};
    const image = run.display_images[mode.window] orelse return .{};
    var value: Image = .{ .dma = image.image.dma, .head = image.head, .window = mode.window,
        .width = image.image.width, .height = image.image.height, .pitch = image.image.pitch, .format = image.image.format,
        .core_point = image.core_point, .window_point = image.window_point, .mode_receipt = image.mode_receipt,
        .link_receipt = if(image.link)|link|link.receipt else 0 };
    if (image.boot_mode) |plan| {
        value.mode = plan.receiver_mode_id; value.sor = plan.signal.sor;
        value.clock_word = plan.signal.clock; value.refresh_micro_hz = plan.refresh_micro_hz;
    }
    return value;
}
pub fn write(ctx: *const r4os.r4dev.DriverContext, comptime format: []const u8, args: anytype) void {
    var buffer: [384]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buffer, format, args) catch {
        ctx.logError("NVIDIA mode-diagnostic: record-overflow"); return;
    };
    ctx.logInfo(text);
}
