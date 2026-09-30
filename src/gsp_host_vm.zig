//! Serialized host-owned GPU VA and MMU v2 page-table lifetime.
//! Table storage is supplied by the driver's common-BO backend. Every PTE
//! mutation remains private to this owner until the PF invalidate completes.
//! GPU users must separately be quiescent before an unmap is admitted.
const std = @import("std");
pub const page = @import("gsp_host_page.zig");
pub const tlb = @import("gsp_host_tlb.zig");
pub const Error = tlb.Error || error{ Busy, Memory, Retained, Descriptor, Exhausted };
// Pacing a single4K entry per dispatcher turn exhausted the5s graphics
// storage deadline on OssiPC's16MB allocation. Batch private table edits,
// with both a count and time bound; publication still waits for the TLB ACK.
pub const edit_pages_per_poll: usize = 64;
pub const edit_budget_ns: u64 = 250 * std.time.ns_per_us;
const Tree = std.Treap(u64, std.math.order);
const TableDescriptor = struct {
    level: page.Level,
    address: u64,
    dma: u64,
    cpu: ?[*]volatile u64,
    parent: ?*Table,
};
pub const Table = struct {
    index: Tree.Node = undefined,
    self_address: usize = 0,
    owner: ?*Owner = null,
    level: page.Level = .root,
    address: u64 = 0,
    dma: u64 = 0,
    cpu: ?[*]volatile u64 = null,
    parent: ?*Table = null,
    descriptor: ?TableDescriptor = null,
    used: u16 = 0,
    retired_next: ?*Table = null,
    retiring: bool = false,
};
pub const Backend = struct {
    context: *anyopaque,
    /// A failed allocation remains owned by the backend until its cleanup.
    allocate: *const fn (*anyopaque) Error!*Table,
    /// Validate the still-held CPU map and DMA lease before table access.
    valid: *const fn (*anyopaque, *const Table) bool,
    /// On error the node remains valid and owned, even after partial cleanup.
    release: *const fn (*anyopaque, *Table) Error!void,
};
pub const Source = struct {
    context: *const anyopaque,
    valid: *const fn (*const anyopaque, u64) bool,
    physical: *const fn (*const anyopaque, u64) Error!u64,
    bytes: u64,
    offset: u64 = 0,
    policy: page.Policy,
};
pub const Range = struct {
    self_address: usize = 0,
    owner: ?*Owner = null,
    serial: u64 = 0,
    address: u64 = 0,
    bytes: u64 = 0,
    previous: ?*Range = null,
    next: ?*Range = null,
    bindings: ?*Binding = null,
};
pub const Binding = struct {
    self_address: usize = 0,
    range: ?*Range = null,
    source: ?Source = null,
    source_stamp: ?Source = null,
    offset: u64 = 0,
    previous: ?*Binding = null,
    next: ?*Binding = null,
    mapped: bool = false,
};
const Work = struct {
    binding: *Binding,
    mapping: bool,
    deadline: u64,
    offset: u64 = 0,
    last_time: u64 = 0,
    phase: enum { editing, invalidating, releasing } = .editing,
    invalidate: ?tlb.Operation = null,
};
pub const Owner = struct {
    self_address: usize = 0,
    epoch: u64 = 0,
    backend: ?Backend = null,
    io: ?tlb.Io = null,
    base: u64 = 0,
    bytes: u64 = 0,
    serial: u64 = 0,
    tables: Tree = .{},
    root: ?*Table = null,
    ranges: ?*Range = null,
    retired: ?*Table = null,
    work: ?Work = null,
    possible_binding: bool = false,
    attached: bool = false,
    failure: ?Error = null,

    pub fn prepare(self: *Owner, epoch: u64, base: u64, bytes: u64, backend: Backend, io: tlb.Io) Error!void {
        if (self.self_address != 0) return error.Busy;
        try page.extent(base, bytes);
        if (epoch == 0 or io.generation(io.context) != epoch) return error.Stale;
        self.self_address = @intFromPtr(self);
        self.epoch = epoch;
        self.base = base;
        self.bytes = bytes;
        self.backend = backend;
        self.io = io;
        self.root = self.createTable(.root, 0, null) catch |err| return self.fail(err);
    }
    fn stable(self: *const Owner) Error!void {
        if (self.self_address != @intFromPtr(self) or self.epoch == 0 or self.io == null or self.backend == null) return error.Stale;
        if (self.io.?.generation(self.io.?.context) != self.epoch) return error.Stale;
        if (self.failure != null) return error.Retained;
    }
    fn fail(self: *Owner, err: Error) Error {
        if (self.failure == null) self.failure = err;
        return err;
    }
    fn nextSerial(self: *Owner) Error!u64 {
        self.serial = std.math.add(u64, self.serial, 1) catch return error.Exhausted;
        return self.serial;
    }
    fn tableValid(self: *const Owner, value: *const Table) Error!void {
        if (value.self_address != @intFromPtr(value) or value.owner != self or value.cpu == null or
            value.descriptor == null or !std.meta.eql(value.descriptor.?, descriptor(value)) or
            @intFromPtr(value.cpu.?) & 4095 != 0 or value.used > page.count(value.level) or
            !self.backend.?.valid(self.backend.?.context, value)) return error.Descriptor;
        if (value.index.key != try page.tableKey(value.level, value.address)) return error.Descriptor;
        _ = try page.directory(value.dma);
    }
    fn descriptor(value: *const Table) TableDescriptor {
        return .{ .level = value.level, .address = value.address, .dma = value.dma, .cpu = value.cpu, .parent = value.parent };
    }
    fn tableEmpty(value: *const Table) bool {
        for (0..512) |at| if (value.cpu.?[at] != 0) return false;
        return true;
    }
    fn createTable(self: *Owner, level: page.Level, address: u64, parent: ?*Table) Error!*Table {
        const key = try page.tableKey(level, address);
        if (self.tables.getEntryFor(key).node != null) return error.Busy;
        const table = try self.backend.?.allocate(self.backend.?.context);
        // The backend keeps ownership even if a malformed descriptor cannot
        // safely be linked into the index. Never lose its pending allocation.
        if (table.self_address != 0 or table.owner != null or table.parent != null or table.descriptor != null or table.used != 0 or
            table.cpu == null or @intFromPtr(table.cpu.?) & 4095 != 0 or table.retiring or table.retired_next != null or
            !self.backend.?.valid(self.backend.?.context, table)) return error.Descriptor;
        _ = try page.directory(table.dma);
        if (!tableEmpty(table)) return error.Descriptor;
        table.self_address = @intFromPtr(table);
        table.owner = self;
        table.level = level;
        table.address = address;
        table.parent = parent;
        table.descriptor = descriptor(table);
        var entry = self.tables.getEntryFor(key);
        entry.set(&table.index);
        return table;
    }
    pub fn rootAddress(self: *const Owner) Error!u64 {
        try self.stable();
        const root = self.root orelse return error.State;
        try self.tableValid(root);
        return root.dma;
    }
    pub fn invalidation(self: *Owner) Error!*tlb.Operation {
        try self.stable();
        if (!self.attached or self.work == null or self.work.?.phase != .invalidating or self.work.?.invalidate == null) return error.State;
        try self.bindingValid(self.work.?.binding);
        return &self.work.?.invalidate.?;
    }
    pub fn bindSubmitted(self: *Owner) Error!void {
        _ = try self.rootAddress();
        if (self.possible_binding or self.attached) return error.State;
        self.possible_binding = true;
        asm volatile ("mfence" ::: .{ .memory = true });
    }
    pub fn bindConfirmed(self: *Owner) Error!void {
        try self.stable();
        if (!self.possible_binding or self.attached) return error.State;
        self.attached = true;
    }
    /// Call only after the original UNSET_PAGE_DIRECTORY response and ACK,
    /// with every channel gone and every mapping/range already retired.
    pub fn unbindConfirmed(self: *Owner) Error!void {
        try self.stable();
        if (!self.attached or self.ranges != null or self.work != null or self.retired != null) return error.Busy;
        self.attached = false;
        self.possible_binding = false;
    }
    fn rangeValid(self: *const Owner, range: *const Range) Error!void {
        if (range.self_address != @intFromPtr(range) or range.owner != self or range.serial == 0) return error.Stale;
        try page.extent(range.address, range.bytes);
        if (range.address < self.base or range.address - self.base > self.bytes or range.bytes > self.bytes - (range.address - self.base)) return error.Bounds;
        if (range.previous) |prev| {
            if (prev.next != range or prev.owner != self or prev.address + prev.bytes > range.address) return error.Stale;
        } else if (self.ranges != range) return error.Stale;
        if (range.next) |next| if (next.previous != range or next.owner != self or range.address + range.bytes > next.address) return error.Stale;
    }
    pub fn reserve(self: *Owner, range: *Range, bytes: u64, alignment: u64, fixed: u64) Error!u64 {
        try self.stable();
        if (!self.attached or self.work != null or range.self_address != 0 or range.owner != null or range.bindings != null) return error.Busy;
        if (alignment < 4096 or alignment > page.va_limit or !std.math.isPowerOfTwo(alignment) or bytes == 0 or bytes & 4095 != 0) return error.Alignment;
        var address = if (fixed != 0) fixed else std.mem.alignForward(u64, @max(self.base, 0x100000000), alignment);
        if (address & (alignment - 1) != 0) return error.Alignment;
        try page.extent(address, bytes);
        var previous: ?*Range = null;
        var next = self.ranges;
        while (next) |entry| {
            try self.rangeValid(entry);
            if (address <= entry.address and bytes <= entry.address - address) break;
            if (address < entry.address + entry.bytes) {
                if (fixed != 0) return error.Busy;
                address = std.mem.alignForward(u64, entry.address + entry.bytes, alignment);
                try page.extent(address, bytes);
            }
            previous = entry;
            next = entry.next;
        }
        if (address < self.base or address - self.base > self.bytes or bytes > self.bytes - (address - self.base)) return error.Bounds;
        range.* = .{ .self_address = @intFromPtr(range), .owner = self, .serial = try self.nextSerial(), .address = address, .bytes = bytes,
            .previous = previous, .next = next };
        if (previous) |entry| entry.next = range else self.ranges = range;
        if (next) |entry| entry.previous = range;
        return address;
    }
    pub fn releaseRange(self: *Owner, range: *Range) Error!void {
        try self.stable();
        try self.rangeValid(range);
        if (range.bindings != null or self.work != null) return error.Busy;
        if (range.previous) |entry| entry.next = range.next else self.ranges = range.next;
        if (range.next) |entry| entry.previous = range.previous;
        range.* = .{};
    }
    fn bindingValid(self: *Owner, binding: *const Binding) Error!void {
        if (binding.self_address != @intFromPtr(binding) or binding.range == null or binding.source == null or
            !std.meta.eql(binding.source, binding.source_stamp)) return error.Stale;
        try self.rangeValid(binding.range.?);
        const source = binding.source.?;
        if (!source.valid(source.context, self.epoch)) return error.Stale;
        if (source.bytes == 0 or source.bytes > binding.range.?.bytes or binding.offset > binding.range.?.bytes - source.bytes) return error.Bounds;
        if (binding.previous) |prev| {
            if (prev.next != binding or prev.range != binding.range) return error.Stale;
        } else if (binding.range.?.bindings != binding) return error.Stale;
        if (binding.next) |next| if (next.previous != binding or next.range != binding.range) return error.Stale;
    }
    pub fn beginMap(self: *Owner, range: *Range, binding: *Binding, offset: u64, source: Source, deadline: u64) Error!void {
        try self.stable();
        try self.rangeValid(range);
        if (!self.attached or self.work != null or binding.self_address != 0 or binding.range != null) return error.Busy;
        if (!source.valid(source.context, self.epoch)) return error.Stale;
        if (source.bytes == 0 or (offset | source.bytes | source.offset) & 4095 != 0 or source.offset > std.math.maxInt(u64) - source.bytes or
            source.bytes > range.bytes or offset > range.bytes - source.bytes) return error.Bounds;
        if (self.io.?.now_ns(self.io.?.context) >= deadline) return error.Deadline;
        var cursor = range.bindings;
        while (cursor) |entry| : (cursor = entry.next) {
            try self.bindingValid(entry);
            if (offset < entry.offset + entry.source.?.bytes and entry.offset < offset + source.bytes) return error.Busy;
        }
        binding.* = .{ .self_address = @intFromPtr(binding), .range = range, .source = source, .source_stamp = source,
            .offset = offset, .next = range.bindings };
        if (range.bindings) |head| head.previous = binding;
        range.bindings = binding;
        self.work = .{ .binding = binding, .mapping = true, .deadline = deadline };
    }
    pub fn beginUnmap(self: *Owner, binding: *Binding, deadline: u64, quiesced: bool) Error!void {
        try self.stable();
        try self.bindingValid(binding);
        if (!quiesced or self.work != null or !binding.mapped or !self.attached) return error.Busy;
        if (self.io.?.now_ns(self.io.?.context) >= deadline) return error.Deadline;
        self.work = .{ .binding = binding, .mapping = false, .deadline = deadline };
    }
    fn slot(table: *const Table, address: u64) Error!usize {
        const offset = try page.byteOffset(table.level, address);
        return offset / 8 + @as(usize, if (table.level == .dual) 1 else 0);
    }
    fn leaf(self: *Owner, address: u64, create: bool) Error!*Table {
        var parent = self.root orelse return error.State;
        for ([_]page.Level{ .pd2, .pd1, .dual, .leaf }) |level| {
            try self.tableValid(parent);
            const at = try slot(parent, address);
            const entry = self.tables.getEntryFor(try page.tableKey(level, address));
            const child: *Table = if (entry.node) |node| @fieldParentPtr("index", node) else blk: {
                if (!create or parent.cpu.?[at] != 0) return error.State;
                const result = try self.createTable(level, address, parent);
                // Empty child storage and metadata exist before a reachable
                // parent entry. Ambiguous later failure retains both.
                asm volatile ("mfence" ::: .{ .memory = true });
                parent.cpu.?[at] = try page.directory(result.dma);
                parent.used += 1;
                break :blk result;
            };
            try self.tableValid(child);
            if (child.retiring or child.parent != parent or child.level != level or
                parent.cpu.?[at] != try page.directory(child.dma) or
                (parent.level == .dual and parent.cpu.?[at - 1] != 0)) return error.Descriptor;
            parent = child;
        }
        return parent;
    }
    fn retireEmpty(self: *Owner, leaf_table: *Table) Error!void {
        var cursor = leaf_table;
        while (cursor.parent) |parent| {
            if (cursor.used != 0) break;
            try self.tableValid(cursor);
            try self.tableValid(parent);
            if (cursor.retiring or !tableEmpty(cursor) or parent.used == 0) return error.Descriptor;
            const at = try slot(parent, cursor.address);
            if (parent.cpu.?[at] != try page.directory(cursor.dma)) return error.Descriptor;
            parent.cpu.?[at] = 0;
            parent.used -= 1;
            cursor.retiring = true;
            cursor.retired_next = self.retired;
            self.retired = cursor;
            cursor = parent;
        }
    }
    pub fn poll(self: *Owner, binding: *Binding) Error!bool {
        try self.stable();
        if (self.work == null or self.work.?.binding != binding) return error.State;
        return self.advance() catch |err| return self.fail(err);
    }
    fn workTime(self: *Owner, work: *Work) Error!u64 {
        const now = self.io.?.now_ns(self.io.?.context);
        if (now < work.last_time or now >= work.deadline) return error.Deadline;
        work.last_time = now;
        return now;
    }
    fn advance(self: *Owner) Error!bool {
        const work = &self.work.?;
        const binding = work.binding;
        try self.bindingValid(binding);
        const started = try self.workTime(work);
        const source = binding.source.?;
        switch (work.phase) {
            .editing => {
                var edited: usize = 0;
                while (work.offset < source.bytes and edited < edit_pages_per_poll) : (edited += 1) {
                    const now = try self.workTime(work);
                    if (edited != 0 and now - started >= edit_budget_ns) break;
                    try self.stable();
                    try self.bindingValid(binding);
                    const address = binding.range.?.address + binding.offset + work.offset;
                    const physical = try source.physical(source.context, source.offset + work.offset);
                    const word = try page.page(physical, source.policy);
                    const table = try self.leaf(address, work.mapping);
                    const at = try slot(table, address);
                    if (work.mapping) {
                        if (table.cpu.?[at] != 0 or table.used == page.count(.leaf)) return error.Busy;
                        table.cpu.?[at] = word;
                        table.used += 1;
                    } else {
                        if (table.cpu.?[at] != word or table.used == 0) return error.Descriptor;
                        table.cpu.?[at] = 0;
                        table.used -= 1;
                        try self.retireEmpty(table);
                    }
                    work.offset += 4096;
                }
                if (work.offset == source.bytes) {
                    _ = try self.workTime(work);
                    work.invalidate = try tlb.Operation.init(self.epoch, try self.rootAddress(), try self.nextSerial(), work.deadline);
                    work.phase = .invalidating;
                }
            },
            .invalidating => {
                if (!try work.invalidate.?.step(self.io.?)) return false;
                const receipt = work.invalidate.?.receipt(self.io.?) orelse return error.Retained;
                if (receipt.epoch != self.epoch or receipt.root_dma != try self.rootAddress() or receipt.serial != self.serial) return error.Stale;
                work.phase = .releasing;
            },
            .releasing => {
                if (self.retired) |table| {
                    try self.tableValid(table);
                    if (!table.retiring or table.used != 0 or !tableEmpty(table)) return error.Descriptor;
                    const next = table.retired_next;
                    // Detach before freeing. Backend retains failures in its
                    // own allocation list; never touch the freed node again.
                    var entry = self.tables.getEntryFor(table.index.key);
                    entry.set(null);
                    self.retired = next;
                    try self.backend.?.release(self.backend.?.context, table);
                    return false;
                }
                if (work.mapping) binding.mapped = true else {
                    if (binding.previous) |entry| entry.next = binding.next else binding.range.?.bindings = binding.next;
                    if (binding.next) |entry| entry.previous = binding.previous;
                    binding.* = .{};
                }
                self.work = null;
                return true;
            },
        }
        return false;
    }
    /// The normal path requires an acknowledged external-root detach. Reset
    /// cleanup is owned by the hardware runtime/backend, never inferred here.
    pub fn close(self: *Owner) Error!void {
        if (self.self_address == 0) return;
        try self.stable();
        if (self.possible_binding or self.attached or self.work != null or self.ranges != null or self.retired != null) return error.Busy;
        if (self.root) |root| {
            try self.tableValid(root);
            if (root.used != 0 or !tableEmpty(root) or self.tables.getMin() != &root.index or self.tables.getMax() != &root.index) return error.Retained;
            var entry = self.tables.getEntryFor(root.index.key);
            entry.set(null);
            self.root = null;
            self.backend.?.release(self.backend.?.context, root) catch |err| return self.fail(err);
        }
        self.* = .{};
    }
};
