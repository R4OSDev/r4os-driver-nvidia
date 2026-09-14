//! Direct images borrow the common queue's source, then acquire an independent
//! read-only display use. The same fence retains final retirement metadata.
//! Table updates and Window methods go through the existing device PUT guards.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const runtime = @import("gsp_runtime.zig");
pub const Phase = enum { retain, bind, upload, uploaded, prepare, flip, visible, unregister, remove, remove_upload, removed, restore };
pub const Work = struct {
    job: a.GfxDriverJob = .{},
    queue: r4os.driver_queue.Context,
    memory: r4os.driver_memory.Context,
    root: runtime.DisplayEngineHandle,
    channel: runtime.ChannelHandle,
    window: runtime.DisplayChannelHandle,
    deadline: u64,
    phase: Phase = .retain,
    reference: a.GfxBufferReference = .{},
    dma: u32 = 0,
    aborting: bool = false,
    activated: bool = false,
    target: ?*runtime.Presentation = null,
    source: ?*runtime.Presentation = null,
    ticket: ?runtime.execution_fifo.copy.Ticket = null,
    submitted: bool = false,

    pub fn step(self: *Work, run: *runtime.Owner, now: u64) !bool {
        if (now >= self.deadline) return error.Timeout; // Retain physical consumers.
        if (self.job.fence.timeline != 0 and !self.activated) {
            const requested = self.queue.scanoutRetireRequested(&self.job.fence);
            if (requested < 0) return error.Queue;
            self.aborting = self.aborting or requested == 1 or run.display_paused;
        }
        switch (self.phase) {
            .retain => {
                if (self.aborting) return self.finish(false);
                const status = self.queue.retainScanout(&self.job.fence, &self.reference);
                if (status != a.gfx_queue_ok and self.reference.reference.id == 0) return self.finish(false);
                if (status != a.gfx_queue_ok or self.reference.version != 1 or self.reference.size < @sizeOf(a.GfxBufferReference) or
                    self.reference.flags != a.gfx_buffer_reference_immutable or self.reference.reserved0 != 0 or
                    self.reference.reference.id == 0 or self.reference.reference.generation == 0 or self.reference.reference.reserved0 != 0 or
                    !std.meta.eql(self.reference.buffer, self.job.source_buffer)) return error.Descriptor;
                self.phase = .bind;
            },
            .bind => {
                if (self.aborting) return self.finish(false);
                self.dma = run.bindDirectImage(self.root, self.window, self.reference) catch |err| {
                    if (err == error.Busy) return false;
                    if (err == error.Unsupported or err == error.Stale or err == error.Memory) return self.finish(false);
                    return err;
                };
                self.phase = .upload;
            },
            .upload => { try run.uploadDisplayTable(self.root, self.channel, self.deadline); self.phase = .uploaded; },
            .uploaded => {
                const status = try run.displayTableStatus(self.root);
                if (status.uploading) return false;
                if (status.revision != status.published_revision) return error.Completion;
                self.phase = if (self.aborting) .remove else .prepare;
            },
            .prepare => {
                if (self.aborting) { self.phase = .remove; return false; }
                try run.prepareDirectImage(self.dma, self.job, self.deadline);
                self.phase = .flip;
            },
            .flip => {
                if (self.aborting) { self.phase = .unregister; return false; }
                try run.flipDisplayPresentationImage(self.dma, self.deadline);
                run.display_flip.?.ordinary = true;
                self.phase = .visible;
            },
            .visible => {
                const entry = try run.directPresentation(self.dma);
                const direct = entry.direct orelse return error.Stale;
                if (!direct.handed_off) {
                    if (run.display_flip == null and run.display_paused) self.phase = .unregister;
                    return false;
                }
                // The display's independent Use and the common fence now
                // retain this source; the setup reference has no further use.
                if (self.reference.reference.id != 0 and self.memory.bufferRelease(&self.reference.reference) != a.gfx_buffer_result_ok) return error.Retained;
                self.reference = .{};
                return true;
            },
            .unregister => { try run.unregisterDirectImage(self.dma); self.phase = .remove; },
            .remove => { try run.removeDisplayImage(self.root, self.window.slot - 1, self.dma); self.phase = .remove_upload; },
            .remove_upload => { try run.uploadDisplayTable(self.root, self.channel, self.deadline); self.phase = .removed; },
            .removed => {
                const status = try run.displayTableStatus(self.root);
                if (status.uploading) return false;
                if (status.revision != status.published_revision or run.display_resources_slot.owner.?.table.indexOf(self.window.slot, self.dma) != null) return error.Completion;
                return self.finish(self.activated);
            },
            .restore => return run.advanceDirectRestore(self, now),
        }
        return false;
    }
    fn finish(self: *Work, success: bool) !bool {
        if (self.reference.reference.id != 0) {
            if (self.memory.bufferRelease(&self.reference.reference) != a.gfx_buffer_result_ok) return error.Retained;
            self.reference = .{};
        }
        if (self.queue.complete(&self.job.fence, if (success) a.gfx_queue_result_complete else a.gfx_queue_result_cancelled, 1) != a.gfx_queue_ok)
            return error.Retained;
        return true;
    }
};
