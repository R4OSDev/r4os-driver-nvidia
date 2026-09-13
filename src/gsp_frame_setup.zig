//! One bounded spare-image allocation. The existing RM/CE/table owners
//! perform every operation; the active image and its SYSTEM shadow survive.
const runtime = @import("gsp_runtime.zig");
pub const Phase = enum { allocate, allocation, bind, creator, upload, uploaded, prepare };
pub const Work = struct {
    image: *runtime.Presentation,
    deadline: u64,
    phase: Phase = .allocate,
    storage: ?runtime.BufferHandle = null,
    dma: u32 = 0,
    pub fn step(self: *Work, run: *runtime.Owner) !bool {
        const clock = run.ctx.?.resources() orelse return error.Api;
        if (clock.nowNs() >= self.deadline) return error.Timeout;
        switch (self.phase) {
            .allocate => {
                const source = self.image.surface.scanout.?;
                self.storage = try run.allocateDisplaySurface(.{ .width = source.width, .height = source.height, .usage = 40 }, self.deadline);
                self.phase = .allocation;
            },
            .allocation => {
                const status = try run.nativeBufferStatus(self.storage.?);
                if (status.state != .handed_off or run.native_active != null) return false;
                if (status.info == null or status.rejected != null or status.host_rejected != null) return error.Memory;
                self.phase = .bind;
            },
            .bind => {
                self.dma = try run.bindDisplayStorage(self.image.root, .window, self.image.window.slot - 1, self.storage.?);
                self.phase = .creator;
            },
            .creator => { try run.releaseNativeBuffer(self.storage.?); self.phase = .upload; },
            .upload => {
                try run.uploadDisplayTable(self.image.root, self.image.channel_handle, self.deadline);
                self.phase = .uploaded;
            },
            .uploaded => {
                const status = try run.displayTableStatus(self.image.root);
                if (status.uploading) return false;
                if (status.revision != status.published_revision) return error.Completion;
                self.phase = .prepare;
            },
            .prepare => { try run.prepareDisplayFrameImage(self.dma, self.deadline); return true; },
        }
        return false;
    }
};
