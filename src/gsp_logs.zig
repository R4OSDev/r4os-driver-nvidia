// Raw ring layout adapted from NVIDIA RM570.144 liblogdecode.c.
// /*
//  * ----------------------------------------------------------------------
//  * Copyright (c) 2005-2014 Rich Felker, et al.
//  * Copyright (c) 2019-2024, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//  *
//  * Permission is hereby granted, free of charge, to any person obtaining
//  * a copy of this software and associated documentation files (the
//  * "Software"), to deal in the Software without restriction, including
//  * without limitation the rights to use, copy, modify, merge, publish,
//  * distribute, sublicense, and/or sell copies of the Software, and to
//  * permit persons to whom the Software is furnished to do so, subject to
//  * the following conditions:
//  *
//  * The above copyright notice and this permission notice shall be
//  * included in all copies or substantial portions of the Software.
//  *
//  * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//  * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//  * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//  * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
//  * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
//  * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
//  * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//  * ----------------------------------------------------------------------
//  */
//! Bounded observations of the five Libos raw log rings. Single init/work
//! owner, never IRQ or concurrent callbacks. No strings/ELF pointers decoded.
//! A stable PUT observation is not an atomic firmware snapshot or health proof.
const std = @import("std");
const init = @import("gsp_init.zig");
const run = @import("gsp_run_memory.zig");
pub const capacity: u64 = init.log_bytes / 8 - 1;
pub const output_bytes: usize = init.log_bytes - 8;
pub const Observation = struct {
    epoch: u64,
    log: usize,
    first_word: u64,
    next_word: u64,
    lost_words: u64,
    word_count: usize,
};
pub const Reader = struct {
    self_address: usize = 0,
    memory: ?*run.Lease = null,
    epoch: u64 = 0,
    previous: [init.log_count]u64 = @splat(0),
    last_clock: u64 = 0,
    enabled: bool = true,
    busy: bool = false,
    counter_regressed: bool = false,
    last_error: ?anyerror = null,

    pub fn open(self: *Reader, memory: *run.Lease) !void {
        if (self.self_address != 0) return error.Busy;
        const epoch = try memory.borrowLogs(@intFromPtr(self));
        self.* = .{ .self_address = @intFromPtr(self), .memory = memory, .epoch = epoch };
    }
    pub fn generation(self: *const Reader) u64 {
        if (self.self_address != @intFromPtr(self) or self.self_address == 0) return 0;
        const memory = self.memory orelse return 0;
        return if (memory.log_owner == self.self_address and memory.generation() == self.epoch) self.epoch else 0;
    }
    /// The native runtime can pause polling without releasing its memory loan.
    pub fn setPolling(self: *Reader, enabled: bool) !void {
        if (self.self_address != @intFromPtr(self) or self.self_address == 0) return error.Stale;
        if (self.busy) return error.Busy;
        if (enabled and (self.generation() == 0 or self.counter_regressed)) return error.Stale;
        self.enabled = enabled;
    }
    fn check(self: *Reader, deadline: u64) !void {
        if (self.generation() == 0) return error.Stale;
        const now = self.memory.?.init_storage.?.clock.?.nowNs();
        if (deadline == 0 or deadline == std.math.maxInt(u64) or now == std.math.maxInt(u64)) return error.InvalidDeadline;
        if (now < self.last_clock) return error.ClockRegression;
        if (now >= deadline) return error.Timeout;
        self.last_clock = now;
    }
    fn read(self: *Reader, deadline: u64, index: usize, offset: usize, output: []u8) !void {
        try self.check(deadline);
        try self.memory.?.logRead(self.self_address, self.epoch, index, offset, output);
        try self.check(deadline);
    }
    fn put(self: *Reader, deadline: u64, index: usize) !u64 {
        var bytes: [8]u8 = undefined;
        try self.read(deadline, index, 0, &bytes);
        return std.mem.readInt(u64, &bytes, .little);
    }
    /// Output is caller-owned chronological raw words, not decoded records.
    /// No returned observation/counter advance on error; partial output is
    /// cleared only after proving that it aliases none of this run's backing.
    pub fn capture(self: *Reader, index: usize, deadline: u64, output: []u8) !Observation {
        if (self.generation() == 0 or self.counter_regressed) return error.Stale;
        if (self.busy) return error.Busy;
        if (!self.enabled) return error.Suspended;
        if (index >= init.log_count or output.len < output_bytes) return error.LogRange;
        try self.memory.?.validateLogOutput(self.self_address, self.epoch, output[0..output_bytes]);
        self.busy = true;
        defer self.busy = false;
        errdefer |err| {
            self.last_error = err;
            @memset(output[0..output_bytes], 0);
        }
        const next = try self.put(deadline, index);
        const prior = self.previous[index];
        if (next < prior) {
            self.counter_regressed = true;
            self.memory.?.invalidate();
            return error.CounterRegression;
        }
        const count = @min(next - prior, capacity);
        const first = next - count;
        var copied: usize = 0;
        while (copied < count) {
            const slot = (first + copied) % capacity;
            const words: usize = @intCast(@min(count - copied, capacity - slot, 4096 / 8));
            try self.read(deadline, index, @intCast(8 + slot * 8), output[copied * 8 ..][0 .. words * 8]);
            copied += words;
        }
        const confirmed = try self.put(deadline, index);
        if (confirmed < next) {
            self.counter_regressed = true;
            self.memory.?.invalidate();
            return error.CounterRegression;
        }
        if (confirmed != next) return error.ProducerChanged;
        self.previous[index] = next;
        self.last_error = null;
        return .{ .epoch = self.epoch, .log = index, .first_word = first, .next_word = next, .lost_words = first - prior, .word_count = @intCast(count) };
    }
    pub fn close(self: *Reader) bool {
        if (self.self_address == 0) return true;
        if (self.self_address != @intFromPtr(self) or self.busy) return false;
        const memory = self.memory orelse return false;
        if (!memory.releaseLogs(self.self_address, self.epoch)) return false;
        self.* = .{};
        return true;
    }
};
