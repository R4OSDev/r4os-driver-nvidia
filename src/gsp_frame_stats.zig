//! Optional shared metadata publication from the serialized device worker.
//! Hardware proof belongs to Runtime; a reporting error never changes video.
const std = @import("std");
const a = @import("r4os").abi;
const Plan = @import("gsp_boot_mode.zig").Plan;
pub const Owner = struct {
    last: ?a.DisplayPresentationStats = null,
    disabled: bool = false,
    last_info: ?a.DisplayPresentationInfo = null,
    info_disabled: bool = false,

    pub fn publish(self: *Owner, product: anytype) void {
        if (!product.callback_confirmed or product.mode == null) return;
        self.publishFor(product, product.mode.?, product.receipt.generation,
            product.failure != null or product.running.?.output_faults[product.mode.?.window] != null, false);
        for (&product.additional.outputs) |*output| {
            if (output.target.display_generation == 0 or output.mode == null) continue;
            output.statistics.publishFor(product, output.mode.?, output.target.display_generation, output.failure != null, true);
        }
    }
    fn publishFor(self: *Owner, product: anytype, mode: Plan, generation: u64, failed: bool, additional: bool) void {
        self.publishInfo(product, mode, generation, failed, additional);
        if (self.disabled or !product.display.?.supportsPresentationStats()) return;
        const run = product.running.?;
        const head = mode.head;
        if (head >= run.flip_receipts.len) return;
        const counters = run.output_frames[mode.window];
        const copying = if (run.copy_job) |work| work.output_window != null and work.output_window.? == mode.window else false;
        const setup = if (run.frame_setup) |work| work.image.window.slot == mode.window + 1 else false;
        var value: a.DisplayPresentationStats = .{
            .flags = a.display_presentation_flag_available | @as(u32, if (failed or run.failure != null) a.display_presentation_flag_lost else 0),
            .head_id = head, .backend = product.backend, .display_generation = generation,
            .sequence = if (self.last) |last| last.sequence else 0,
            .buffer_count = run.presentation_buffers,
            .acquired_count = counters.acquired, .rendered_count = counters.rendered, .rejected_count = counters.rejected,
            .submitted_count = counters.submitted, .visible_count = counters.visible, .released_count = counters.released,
            .pending = @as(u32, if (copying) a.display_presentation_pending_copy else 0) |
                @as(u32, if (run.readyImage(mode.window) != null) a.display_presentation_pending_ready else 0) |
                @as(u32, if (run.displayFlip(mode.window) != null) a.display_presentation_pending_flip else 0) |
                @as(u32, if (setup) a.display_presentation_pending_setup else 0),
        };
        if (run.flip_receipts[head]) |receipt| {
            if (receipt.direct) value.flags |= a.display_presentation_flag_direct;
            value.visible_sequence = receipt.sequence;
            value.source_timeline = receipt.source_timeline; value.source_point = receipt.source_point;
            value.render_point = receipt.render_point; value.window_point = receipt.window_point;
            value.submitted_ns = receipt.submitted_ns; value.visible_ns = receipt.begun_observed_ns;
            value.gpu_timestamp = receipt.begun_gpu_timestamp;
            value.irq_sequence = receipt.head_observation.sequence; value.irq_observed_ns = receipt.head_observation.observed_ns;
            value.released_ns = receipt.previous_released_ns;
        }
        if (self.last) |last| if (std.meta.eql(value, last)) return;
        if (value.sequence == std.math.maxInt(u64)) { self.disabled = true; return; }
        value.sequence += 1;
        const status = product.display.?.presentationStats(&value);
        if (status == a.gfx_output_ok) self.last = value else if (status != a.gfx_output_error_busy) {
            self.disabled = true;
            @import("gsp_mode_diagnostics.zig").write(&product.ctx.?, "NVIDIA present-statistics: unavailable status={d} video=preserved", .{status});
        }
    }
    fn publishInfo(self: *Owner, product: anytype, base: Plan, generation: u64, failed: bool, additional: bool) void {
        if (self.info_disabled or !product.display.?.supportsPresentationInfo()) return;
        const run = product.running.?;
        const mode = if (run.display_images[base.window]) |image| image.boot_mode orelse base else base;
        if (run.presentation_buffers < 2 or run.presentation_buffers > 3 or mode.head >= 8) return;
        const current = run.currentPresentation(mode.window);
        const direct = current != null and current.?.direct != null;
        var value: a.DisplayPresentationInfo = .{ .head_id = mode.head, .backend = product.backend,
            // Additional registration seeds the common metadata at sequence1.
            .display_generation = generation, .sequence = if (self.last_info) |last| last.sequence else @intFromBool(additional),
            .width = mode.width, .height = mode.height, .format = a.gfx_buffer_format_xrgb8888,
            .policies = 3, .buffer_count = run.presentation_buffers, .plane_count = 1,
            .path = if (direct) 2 else 1,
            // Window SET_PRESENT_CONTROL uses non-tearing interval1. Latest
            // ready changes only the unsubmitted userland queue, not that mode.
            .flags = a.display_presentation_info_native | a.display_presentation_info_synchronized | a.display_presentation_info_visibility |
                @as(u32, if (!additional and run.directOutputAvailable(mode.window)) a.display_presentation_info_direct else 0) |
                @as(u32, if (run.outputPaused(mode.window)) a.display_presentation_info_occluded else a.display_presentation_info_active) |
                @as(u32, if (failed or run.failure != null) a.display_presentation_info_lost else 0),
            .interval_ns = if (mode.refresh_micro_hz == 0) 0 else 1_000_000_000_000_000 / mode.refresh_micro_hz };
        if (self.last_info) |last| {
            value.observed_sequence = last.observed_sequence; value.observed_ns = last.observed_ns;
        }
        if (run.head_events) |events| if (events.enabled and events.epoch == run.epoch and events.head_mask & (@as(u32, 1) << @intCast(mode.head)) != 0) {
            if (events.heads[mode.head].snapshot()) |sample| {
                value.observed_sequence = sample.sequence; value.observed_ns = sample.observed_ns;
            }
        };
        if (self.last_info) |last| if (std.meta.eql(value, last)) return;
        if (value.sequence == std.math.maxInt(u64)) { self.info_disabled = true; return; }
        value.sequence += 1;
        const status = product.display.?.presentationInfo(&value);
        if (status == a.gfx_output_ok) self.last_info = value else if (status != a.gfx_output_error_busy and status != a.gfx_output_error_stale) {
            self.info_disabled = true;
            @import("gsp_mode_diagnostics.zig").write(&product.ctx.?, "NVIDIA presentation-info: unavailable status={d} video=preserved", .{status});
        }
    }
};
