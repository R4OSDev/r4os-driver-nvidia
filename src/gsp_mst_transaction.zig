//! Resident before/after tables for one root transaction. The active work
//! carries Token digests; completed image plans retain only signal intent.
//! An ambiguous hardware operation retains
//! this journal and every referenced RM ID until recovery proves retirement.
const std = @import("std");
const budget = @import("gsp_mst_budget.zig");
const registry = @import("gsp_mst_registry.zig");
pub const Token = struct {
    epoch: u64, root: u32, generation: u64, serial: u64, revision: u64,
    before: [32]u8, after: [32]u8,
};
pub const Phase = enum { vacant, reserved, posted, restoring, disconnected, committed, restored, retained };
pub const Journal = struct {
    phase: Phase = .vacant,
    token: ?Token = null,
    previous: budget.State = .{},
    target: budget.Budget = .{ .link = .{ .rate = 0, .lanes = 0 }, .table = .{} },
    handles: [16]registry.Handle = @splat(.{ .epoch = 0, .serial = 0, .slot = 0 }),
    handle_count: u8 = 0,
    first_posted: u64 = 0,
    last_receipt: u64 = 0,
    missing_receipt: u64 = 0,
    stopped_heads: u8 = 0,
    /// Reserve as one transaction. Failure leaves both this journal and all
    /// registry entries unchanged. serial belongs to a resident root counter.
    pub fn reserve(self: *Journal, ids: *registry.Registry, epoch: u64, root: u32, generation: u64, serial: u64,
        previous: *const budget.State, target: *const budget.Budget) !Token
    {
        if (self.phase != .vacant or self.token != null) return error.Busy;
        if (epoch == 0 or ids.epoch != epoch or root == 0 or root & (root - 1) != 0 or generation == 0 or serial == 0 or
            (previous.epoch != 0 and (previous.epoch != epoch or previous.root != root)) or
            previous.revision == std.math.maxInt(u64)) return error.Stale;
        if (previous.table.count != 0 and (previous.epoch != epoch or previous.revision == 0 or previous.completion_receipt == 0 or
            previous.training == null or previous.training.?.receipt == 0 or !std.meta.eql(previous.training.?.link, target.link))) return error.Stale;
        try budget.validateTable(&previous.table, epoch, root, target.link);
        try budget.validateTable(&target.table, epoch, root, target.link);
        const token: Token = .{ .epoch = epoch, .root = root, .generation = generation, .serial = serial,
            .revision = previous.revision, .before = try previous.table.digest(), .after = try target.table.digest() };
        var handles: [16]registry.Handle = undefined;
        var count: u8 = 0;
        for ([_]*const budget.Table{ &previous.table, &target.table }) |table| for (table.entries[0..table.count]) |*entry| {
            var found = false;
            for (handles[0..count]) |handle| if (std.meta.eql(handle, entry.handle)) { found = true; };
            if (!found) { handles[count] = entry.handle; count += 1; }
        };
        if (count == 0) return error.Descriptor;
        try ids.holdStreams(.{ .epoch = epoch, .root = root, .serial = serial }, handles[0..count]);
        self.previous = previous.*; self.target = target.*;
        @memcpy(self.handles[0..count], handles[0..count]);
        self.handle_count = count; self.token = token; self.phase = .reserved;
        return token;
    }
    pub fn validate(self: *const Journal, token: Token, current: *const budget.State) !void {
        if (self.phase == .vacant or self.token == null or !std.meta.eql(self.token.?, token) or
            current.revision != token.revision or (current.epoch != 0 and (current.epoch != token.epoch or current.root != token.root)) or
            current.completion_receipt != self.previous.completion_receipt or !std.meta.eql(current.training, self.previous.training) or
            !std.meta.eql(try current.table.digest(), token.before) or
            !std.meta.eql(try self.previous.table.digest(), token.before) or
            !std.meta.eql(try self.target.table.digest(), token.after)) return error.Stale;
    }
    /// Called by the live exchange owner when a mutating request enters the
    /// waiting phase. A failed/ambiguous response cannot undo this ownership.
    pub fn posted(self: *Journal, token: Token, submission: u64) !void {
        if (self.token == null or !std.meta.eql(self.token.?, token) or submission == 0 or
            (self.phase != .reserved and self.phase != .posted and self.phase != .restoring and self.phase != .disconnected)) return error.Stale;
        if (self.first_posted == 0) self.first_posted = submission;
        if (self.phase == .reserved) self.phase = .posted;
    }
    /// Runtime has acknowledged the ring before supplying a control receipt.
    pub fn receipt(self: *Journal, token: Token, serial: u64) !void {
        if (self.token == null or !std.meta.eql(self.token.?, token) or serial == 0 or serial <= self.last_receipt or
            self.phase == .vacant or self.phase == .committed or self.phase == .restored) return error.Stale;
        self.last_receipt = serial;
    }
    pub fn restoring(self: *Journal, token: Token) !void {
        if (self.token == null or !std.meta.eql(self.token.?, token) or self.phase != .posted or self.first_posted == 0) return error.Stale;
        self.phase = .restoring;
    }
    /// The specific physical root returned CONNECTED=0 on the real exchange.
    /// Keep its complete old table and every ID while independent Core/Window
    /// owners retire the heads. There is no receiver ACT while it is absent.
    pub fn disconnected(self: *Journal, token: Token, current: *const budget.State, serial: u64) !Token {
        try self.validate(token, current);
        if (self.phase != .posted or self.previous.table.count == 0 or self.missing_receipt != 0 or
            serial == 0 or serial != self.last_receipt) return error.Stale;
        self.target.table = .{};
        var next = token; next.after = try self.target.table.digest();
        self.token = next; self.phase = .disconnected; self.missing_receipt = serial;
        return next;
    }
    /// One real source/Head stop. Earlier heads remain leased until the last
    /// one completes; the old table is never falsely compacted without ACT.
    pub fn disconnectedHead(self: *Journal, ids: *registry.Registry, token: Token, current: *budget.State,
        display_id: u32, previous: registry.Image, core_point: u64, window_point: u64, source: u64, last: u64) !bool
    {
        try self.validate(token, current);
        if (self.phase != .disconnected or self.missing_receipt == 0 or source <= self.missing_receipt or
            last <= source or last != self.last_receipt or ids.epoch != token.epoch) return error.Stale;
        const entry = self.previous.table.find(display_id) orelse return error.Stale;
        if (previous.head != entry.allocation.head or previous.window != entry.window or
            core_point <= previous.core_point or window_point <= previous.window_point or
            !std.meta.eql(entry.handle, try ids.handle(entry.handle.slot))) return error.Stale;
        const image = ids.slots[entry.handle.slot].image orelse return error.Stale;
        if (!std.meta.eql(previous, image)) return error.Stale;
        const mask = @as(u8, 1) << @intCast(previous.head);
        if (self.stopped_heads & mask != 0) return error.Stale;
        const stopped_mask = self.stopped_heads | mask;
        var all: u8 = 0;
        for (self.previous.table.entries[0..self.previous.table.count]) |*item| all |= @as(u8, 1) << @intCast(item.allocation.head);
        if (stopped_mask != all) { self.stopped_heads = stopped_mask; return false; }
        try ids.releaseStreams(.{ .epoch = token.epoch, .root = token.root, .serial = token.serial }, self.handles[0..self.handle_count]);
        current.* = .{ .epoch = token.epoch, .root = token.root, .revision = token.revision + 1, .completion_receipt = last };
        self.* = .{};
        return true;
    }
    /// Only an empty root's first stream may choose another trained link.
    /// The live owner calls this after an acknowledged training/config/lane
    /// failure and before source/payload programming. No ID or mode changes.
    pub fn retargetTraining(self: *Journal, token: Token, current: *const budget.State, desired: *const budget.Budget, serial: u64) !Token {
        try self.validate(token, current);
        if (self.phase != .posted or self.previous.table.count != 0 or self.target.table.count != 1 or desired.table.count != 1 or
            serial == 0 or serial != self.last_receipt) return error.Stale;
        try budget.validateTable(&desired.table, token.epoch, token.root, desired.link);
        var old = self.target.table.entries[0];
        const next = desired.table.entries[0];
        if (old.allocation.display_id != next.allocation.display_id or old.allocation.head != next.allocation.head or
            old.allocation.payload_id != next.allocation.payload_id or next.allocation.start != 1) return error.Stale;
        old.allocation = next.allocation;
        if (!std.meta.eql(old, next)) return error.Stale;
        var updated = token; updated.after = try desired.table.digest();
        self.target = desired.*; self.token = updated;
        return updated;
    }
    /// This is only for a work item whose real Exchange.cancelPrepared has
    /// finished, or which has not prepared a request. Posted work must go
    /// through the live rollback sequence; a timeout is never cancellation.
    pub fn cancelUnsubmitted(self: *Journal, ids: *registry.Registry, token: Token) !void {
        if (self.token == null or !std.meta.eql(self.token.?, token) or self.phase != .reserved or self.first_posted != 0) return error.Retained;
        try ids.releaseStreams(.{ .epoch = token.epoch, .root = token.root, .serial = token.serial }, self.handles[0..self.handle_count]);
        self.* = .{};
    }
    pub fn retain(self: *Journal) void {
        if (self.phase != .vacant) self.phase = .retained;
    }
    /// The live owner has completed source programming, receiver ACT, every
    /// branch allocation and rate governing. This is the sole table install.
    /// The last receipt is an acknowledged RM ticket, never a local counter.
    pub fn commit(self: *Journal, ids: *registry.Registry, token: Token, current: *budget.State,
        training: budget.Training, receipt_serial: u64) !u64
    {
        try self.validate(token, current);
        if (self.phase != .posted or self.first_posted == 0 or receipt_serial == 0 or receipt_serial != self.last_receipt or
            training.receipt == 0 or training.receipt >= receipt_serial or !std.meta.eql(training.link, self.target.link) or
            !@import("gsp_dp_link.zig").trained(training.lanes, training.link.lanes)) return error.Stale;
        try ids.releaseStreams(.{ .epoch = token.epoch, .root = token.root, .serial = token.serial }, self.handles[0..self.handle_count]);
        current.* = .{ .epoch = token.epoch, .root = token.root, .revision = token.revision + 1,
            .table = self.target.table, .training = training, .completion_receipt = receipt_serial };
        const revision = current.revision;
        self.* = .{};
        return revision;
    }
    /// A recovery owner has restored the candidate's Core/Window state and
    /// rebuilt the old root table under rate governing. Empty roots require
    /// a proven source stop and cleared receiver; running roots require the
    /// additional training/ACT/branch/rate receipts.
    pub fn restored(self: *Journal, ids: *registry.Registry, token: Token, current: *budget.State,
        training: ?budget.Training, source: u64, cleared: u64, act: u64, branches: u64, last: u64) !u64
    {
        return self.finishRebuild(ids, token, current, training, source, cleared, act, branches, last, true);
    }
    /// A normal detach rebuilds the remaining target table. It starts its
    /// own transaction; no fictional failed submission is used for removal.
    pub fn stopped(self: *Journal, ids: *registry.Registry, token: Token, current: *budget.State,
        training: ?budget.Training, source: u64, cleared: u64, act: u64, branches: u64, last: u64) !u64
    {
        return self.finishRebuild(ids, token, current, training, source, cleared, act, branches, last, false);
    }
    fn finishRebuild(self: *Journal, ids: *registry.Registry, token: Token, current: *budget.State,
        training: ?budget.Training, source: u64, cleared: u64, act: u64, branches: u64, last: u64, restore: bool) !u64
    {
        try self.validate(token, current);
        const goal_table = if (restore) &self.previous.table else &self.target.table;
        if (self.phase != @as(Phase, if (restore) .restoring else .posted) or self.first_posted == 0 or source == 0 or cleared <= source or
            last != self.last_receipt or last < cleared) return error.Stale;
        if (goal_table.count != 0) {
            const proof = training orelse return error.Stale;
            if (proof.receipt == 0 or proof.receipt >= source or self.previous.training == null or
                !std.meta.eql(proof.link, self.previous.training.?.link) or !std.meta.eql(proof.source, self.previous.training.?.source) or
                !std.mem.eql(u8, &proof.dpcd, &self.previous.training.?.dpcd) or
                !@import("gsp_dp_link.zig").trained(proof.lanes, proof.link.lanes) or act <= cleared or branches <= act or last <= branches)
                return error.Stale;
        } else if (training != null or act != 0 or branches != 0) return error.Stale;
        try ids.releaseStreams(.{ .epoch = token.epoch, .root = token.root, .serial = token.serial }, self.handles[0..self.handle_count]);
        current.* = .{ .epoch = token.epoch, .root = token.root, .revision = token.revision + 1,
            .table = goal_table.*, .training = training, .completion_receipt = last };
        const revision = current.revision;
        self.* = .{};
        return revision;
    }
};
