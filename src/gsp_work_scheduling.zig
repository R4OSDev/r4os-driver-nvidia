//! Bounded admission and producer turns. Hardware owners call yield only
//! after their exact physical completion; this metadata grants no quiescence.
const std = @import("std");
const a = @import("r4os").abi;
pub const capacity = 8;
pub const copy_bytes = 1024 * 1024;
pub const render_pixels = 256 * 1024;
pub const Producer = struct { kind: u32, id: u64, generation: u64 };
const Entry = struct { producer: Producer, producer_turn: u64, job_turn: u64 = 0 };
pub const Owner = struct {
    entries: [capacity]?Entry = @splat(null),
    turn: u64 = 0,
    slices: u64 = 0,
    high_water: u32 = 0,
    copy_limit: u32 = copy_bytes,
    render_limit: u32 = render_pixels,
    /// Driver-local tuning may lower a quantum only between complete jobs.
    pub fn configure(self: *Owner, copy_limit: u32, render_limit: u32) !void {
        if (self.count() != 0) return error.Busy;
        if (copy_limit == 0 or copy_limit > copy_bytes or render_limit == 0 or render_limit > render_pixels) return error.Bounds;
        self.copy_limit = copy_limit; self.render_limit = render_limit;
    }
    pub fn free(self: *const Owner) ?usize {
        for (&self.entries, 0..) |*entry, i| if (entry.* == null) return i;
        return null;
    }
    pub fn count(self: *const Owner) u32 {
        var n: u32 = 0;
        for (&self.entries) |*entry| if (entry.* != null) { n += 1; };
        return n;
    }
    pub fn admit(self: *Owner, index: usize, job: a.GfxDriverJob) !void {
        if (index >= capacity or self.entries[index] != null or job.fence.timeline == 0) return error.State;
        const known = job.size >= @sizeOf(a.GfxDriverJob) and job.producer_kind != 0;
        if (known and (job.producer_kind > 3 or job.producer_reserved != 0 or job.producer_id == 0 or job.producer_generation == 0)) return error.Descriptor;
        const producer: Producer = if (known) .{ .kind = job.producer_kind, .id = job.producer_id, .generation = job.producer_generation }
            else .{ .kind = 0, .id = job.fence.timeline, .generation = job.fence.device_generation };
        // New/returning producers join at the current turn. Giving them zero
        // would let a stream of short jobs starve a retained long operation.
        var last: u64 = self.turn;
        for (&self.entries) |*entry| if (entry.*) |peer| {
            if (std.meta.eql(peer.producer, producer)) { last = peer.producer_turn; break; }
        };
        self.entries[index] = .{ .producer = producer, .producer_turn = last, .job_turn = self.turn };
        self.high_water = @max(self.high_water, self.count());
    }
    pub fn choose(self: *const Owner) ?usize {
        var chosen: ?usize = null;
        for (&self.entries, 0..) |*entry, i| if (entry.*) |candidate| {
            if (chosen) |previous| {
                const other = self.entries[previous].?;
                if (candidate.producer_turn > other.producer_turn or
                    (candidate.producer_turn == other.producer_turn and candidate.job_turn >= other.job_turn)) continue;
            }
            chosen = i;
        };
        return chosen;
    }
    pub fn yield(self: *Owner, index: usize) !void {
        if (index >= capacity or self.entries[index] == null or self.turn == std.math.maxInt(u64)) return error.Exhausted;
        self.turn += 1;
        self.slices +|= 1;
        const producer = self.entries[index].?.producer;
        for (&self.entries) |*entry| if (entry.*) |*peer| {
            if (std.meta.eql(peer.producer, producer)) peer.producer_turn = self.turn;
        };
        self.entries[index].?.job_turn = self.turn;
    }
    pub fn release(self: *Owner, index: usize) !void {
        try self.yield(index);
        self.entries[index] = null;
    }
};
