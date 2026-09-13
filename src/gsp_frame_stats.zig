//! Optional shared metadata publication from the serialized device worker.
//! Hardware proof belongs to Runtime; a reporting error never changes video.
const std = @import("std");
const a = @import("r4os").abi;
pub const Owner = struct {
    last: ?a.DisplayPresentationStats = null,
    disabled: bool = false,

    pub fn publish(self: *Owner, product: anytype) void {
        if (self.disabled or !product.callback_confirmed or product.mode == null or !product.display.?.supportsPresentationStats()) return;
        const run = product.running.?;
        const head = product.mode.?.head;
        if (head >= run.flip_receipts.len) return;
        var value: a.DisplayPresentationStats = .{
            .flags = a.display_presentation_flag_available | @as(u32, if (product.failure != null or run.failure != null) a.display_presentation_flag_lost else 0),
            .head_id = head, .backend = product.backend, .display_generation = product.receipt.generation,
            .sequence = if (self.last) |last| last.sequence else 0,
            .buffer_count = run.presentation_buffers,
            .acquired_count = run.frames_acquired, .rendered_count = run.frames_rendered, .rejected_count = run.frames_rejected,
            .submitted_count = run.flip_issued, .visible_count = run.flip_visible, .released_count = run.flip_released,
            .pending = @as(u32, if (run.copy_job != null) a.display_presentation_pending_copy else 0) |
                @as(u32, if (run.frame_ready != null) a.display_presentation_pending_ready else 0) |
                @as(u32, if (run.display_flip != null) a.display_presentation_pending_flip else 0) |
                @as(u32, if (run.frame_setup != null) a.display_presentation_pending_setup else 0),
        };
        if (run.flip_receipts[head]) |receipt| {
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
};
