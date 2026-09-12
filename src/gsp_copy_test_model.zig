// Host-only CE executor. Command fetch, GPU data and CPU visibility are separate
// views; production submits the encoded methods and never calls this model.
const std = @import("std");
const a = @import("r4os").abi;
const t = std.testing;
const native = @import("gsp_vram_test_model.zig").Model;
const fifo = @import("gsp_fifo_test_model.zig").Model;
pub const Model = struct {
    pub const length = 12288;
    pub const binding: a.GfxBackendBinding = .{ .adapter_id = 0x01000000, .milestone = 1, .device_generation = 7, .reset_generation = 11 };
    const Reference = struct { active: bool = false, buffer: a.GfxBufferHandle = .{} };
    var references: [16]Reference = @splat(.{});
    var original: a.GfxDriverMemoryApi = .{};
    pub var host: [2][length]u8 = undefined;
    var gpu_data: [2][length]u8 = undefined;
    pub var vram_data: [65536]u8 = undefined;
    var command_view: [length]u8 = undefined;
    pub var dma: [2]a.GfxDeviceLease = @splat(.{});
    pub var gpu: [2]a.GfxDeviceLease = @splat(.{});
    pub var job: a.GfxDriverJob = .{};
    pub var queued = false;
    pub var active = false;
    pub var completed: usize = 0;
    pub var result: u32 = 0;
    pub var lost = false;
    pub var unregisters: usize = 0;
    pub var reject_resource = false;
    pub var native_index: usize = 0;
    var app_reference = false;
    var decoded: [17]u32 = undefined;
    var fetched = false;
    var executed = false;
    var signaled = false;
    pub fn install(table: *a.DriverApi, index: usize) void {
        std.debug.assert(table.gfx_memory_query.?(&original) == a.gfx_buffer_result_ok);
        table.gfx_memory_query = memory; table.gfx_queue_query = queue;
        references = @splat(.{}); dma = @splat(.{}); gpu = @splat(.{}); queued = false; active = false;
        completed = 0; result = 0; lost = false; unregisters = 0; reject_resource = false; native_index = index; fetched = false; executed = false; signaled = false;
        app_reference = true; native.slots[index].imported = true; // Separate app alias, independent of the allocator's producer reference.
        for (0..2) |i| { @memset(&host[i], 0xa5); @memset(&gpu_data[i], 0x5a); }
        @memset(&vram_data, 0xcc);
    }
    pub fn address(index: usize) u64 { return 0x80000000 + index * 0x100000; }
    fn sys(index: usize) a.GfxBufferHandle { return .{ .id = @intCast(1101 + index), .generation = 901 }; }
    fn ref(index: usize) a.GfxBufferHandle { return .{ .id = @intCast(1501 + index), .generation = 951 }; }
    fn select(input: a.GfxBufferHandle) ?usize { for (0..references.len) |i| if (std.meta.eql(input, ref(i))) return i; return null; }
    fn system(input: a.GfxBufferHandle) ?usize { for (0..2) |i| if (std.meta.eql(input, sys(i))) return i; return null; }
    fn heldNative() bool {
        if (active or app_reference) return true;
        for (references) |entry| if (entry.active and std.meta.eql(entry.buffer, native.slots[native_index].reservation.buffer)) return true;
        return false;
    }
    pub fn enqueue(readback: bool) void {
        std.debug.assert(!active and !queued and !lost);
        const point = completed + 1;
        job = .{ .fence = .{ .slot = 1, .adapter_id = binding.adapter_id, .timeline = 19, .point = point,
                .device_generation = binding.device_generation, .reset_generation = binding.reset_generation },
            .operation = if (readback) a.gfx_queue_operation_copy else a.gfx_queue_operation_upload,
            .source_buffer = if (readback) native.slots[native_index].reservation.buffer else sys(0),
            .target_buffer = if (readback) sys(1) else native.slots[native_index].reservation.buffer,
            .source_offset = if (readback) 129 else 33, .target_offset = if (readback) 71 else 129, .byte_length = 4091 };
        queued = true; fetched = false; executed = false; signaled = false;
    }
    fn queue(out: *a.GfxDriverQueueApi) callconv(.c) i32 { out.* = .{ .unregister_backend = @intFromPtr(&unregister), .take = @intFromPtr(&take), .retain_resource = @intFromPtr(&retain), .complete = @intFromPtr(&complete) }; return a.gfx_queue_ok; }
    fn unregister(input: *const a.GfxBackendBinding, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(input.*, binding) and quiesced == 0 and !lost);
        lost = true; unregisters += 1; queued = false;
        if (active) result = a.gfx_queue_result_device_lost;
        // Logical terminal result does not acknowledge the running GPU access.
        return if (active) a.gfx_queue_error_busy else a.gfx_queue_ok;
    }
    fn take(input: *const a.GfxBackendBinding, out: *a.GfxDriverJob) callconv(.c) i32 {
        std.debug.assert(std.meta.eql(input.*, binding));
        if (lost) return a.gfx_queue_error_busy;
        if (!queued or active) return a.gfx_queue_error_busy;
        queued = false; active = true; out.* = job;
        // Common queue acquisition is after the app's CPU store boundary.
        // In particular readback CPU bytes do not yet reflect device writes.
        gpu_data[0] = host[0]; gpu_data[1] = host[1]; native.slots[native_index].imported = true;
        return a.gfx_queue_ok;
    }
    fn retain(input: *const a.GfxFence, which: u32, out: *a.GfxBufferReference) callconv(.c) i32 {
        if (!active or !std.meta.eql(input.*, job.fence) or which >= 2) return a.gfx_queue_error_invalid;
        if (reject_resource and which == 1) return a.gfx_queue_error_capacity;
        for (&references, 0..) |*entry, i| if (!entry.active) {
            entry.* = .{ .active = true, .buffer = if (which == 0) job.source_buffer else job.target_buffer };
            out.* = .{ .reference = ref(i), .buffer = entry.buffer, .flags = a.gfx_buffer_reference_mapping_only }; return a.gfx_queue_ok;
        };
        return a.gfx_queue_error_capacity;
    }
    fn complete(input: *const a.GfxFence, status: u32, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(active and !lost and std.meta.eql(input.*, job.fence) and quiesced == 1);
        std.debug.assert(status == a.gfx_queue_result_complete or status == a.gfx_queue_result_failed);
        if (status == a.gfx_queue_result_complete) std.debug.assert(signaled and executed);
        active = false; result = status; completed += 1; native.slots[native_index].imported = heldNative(); return a.gfx_queue_ok;
    }
    fn memory(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = original;
        out.buffer_describe = @intFromPtr(&describe); out.buffer_release = @intFromPtr(&drop);
        out.device_acquire = @intFromPtr(&acquire); out.device_segment = @intFromPtr(&segment); out.device_release = @intFromPtr(&releaseDevice);
        return a.gfx_buffer_result_ok;
    }
    fn describe(input: *const a.GfxBufferHandle, out: *a.GfxBufferDescriptor) callconv(.c) i32 {
        const index = select(input.*) orelse { const call: *const fn (*const a.GfxBufferHandle, *a.GfxBufferDescriptor) callconv(.c) i32 = @ptrFromInt(original.buffer_describe); return call(input, out); };
        const entry = references[index]; std.debug.assert(entry.active);
        out.* = if (system(entry.buffer) != null) .{ .byte_length = length - 5, .alignment = 4096, .usage = 15 }
            else native.slots[native_index].descriptor;
        return a.gfx_buffer_result_ok;
    }
    fn drop(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        const index = select(input.*) orelse { const call: *const fn (*const a.GfxBufferHandle) callconv(.c) i32 = @ptrFromInt(original.buffer_release); return call(input); };
        std.debug.assert(references[index].active); references[index].active = false;
        native.slots[native_index].imported = heldNative(); return a.gfx_buffer_result_ok;
    }
    fn acquire(input: *const a.GfxBufferHandle, request: *const a.GfxDeviceRequest, out: *a.GfxDeviceLease) callconv(.c) i32 {
        const index = select(input.*).?; const entry = references[index]; const i = system(entry.buffer).?;
        std.debug.assert(entry.active and request.byte_offset == 0 and request.byte_length == length);
        const virtual = request.access == 3;
        if (virtual) std.debug.assert(dma[i].lease.id != 0 and gpu[i].lease.id == 0 and request.gpu_virtual_address == address(i) and request.address_space == 1)
        else std.debug.assert(dma[i].lease.id == 0 and request.access == 4 and request.address_space == 0);
        out.* = .{ .lease = .{ .id = @intCast(1701 + i * 2 + @intFromBool(virtual)), .generation = 991 }, .byte_length = length,
            .gpu_virtual_address = request.gpu_virtual_address, .device_generation = request.device_generation, .adapter_id = request.adapter_id,
            .driver_owner = 7, .access = request.access, .address_space = request.address_space, .dma_mask = request.dma_mask };
        if (virtual) gpu[i] = out.* else dma[i] = out.*;
        return a.gfx_buffer_result_ok;
    }
    fn segment(input: *const a.GfxDeviceLease, offset: u64, out: *a.GfxDmaSegment) callconv(.c) i32 {
        const i = (input.lease.id - 1701) / 2;
        std.debug.assert(std.meta.eql(input.*, dma[i]) and offset < length and offset & 4095 == 0);
        out.* = .{ .dma_address = 0x6000000000 + @as(u64, i) * 0x100000 + offset * 2, .byte_length = 4096, .next_offset = offset + 4096 };
        return a.gfx_buffer_result_ok;
    }
    fn releaseDevice(input: *const a.GfxDeviceLease, quiesced: u32) callconv(.c) i32 {
        const i = (input.lease.id - 1701) / 2; std.debug.assert(quiesced == 1 and !active);
        if (input.access == 3) { std.debug.assert(std.meta.eql(input.*, gpu[i])); gpu[i] = .{}; }
        else { std.debug.assert(gpu[i].lease.id == 0 and std.meta.eql(input.*, dma[i])); dma[i] = .{}; }
        return a.gfx_buffer_result_ok;
    }
    fn word(bytes: []const u8, at: usize) u32 { return std.mem.readInt(u32, bytes[at..][0..4], .little); }
    fn operand(hi: u32, lo: u32) u64 { return (@as(u64, hi) << 32) | lo; }
    fn data(address_value: u64, bytes: usize) ![]u8 {
        for (0..2) |i| if (address_value >= address(i) and address_value - address(i) < length) {
            const offset: usize = @intCast(address_value - address(i));
            if (bytes > length - offset or gpu[i].lease.id == 0) return error.GpuAddress;
            return gpu_data[i][offset..][0..bytes];
        };
        const base = native.address(native_index);
        if (address_value < base or address_value - base > vram_data.len or bytes > vram_data.len - (address_value - base)) return error.GpuAddress;
        const offset: usize = @intCast(address_value - base); return vram_data[offset..][0..bytes];
    }
    pub fn fetch(owner: *@import("gsp_fifo.zig").Owner, mmio: []const u8) !void {
        try t.expect(active and !fetched and owner.ring.pending == null);
        try t.expect(word(mmio, 0xbb0090) == owner.work_submit_token.?);
        // The device observes commands only at the published doorbell boundary.
        command_view = fifo.slots[0].data;
        const put = word(&command_view, 8192 + 0x8c);
        try t.expect(put == owner.ring.put and put < 512);
        const index = (put + 511) % 512;
        const low = word(&command_view, index * 8); const high = word(&command_view, index * 8 + 4);
        try t.expect(high >> 10 == 17 and high & 0x300 == 0 and low & 3 == 0);
        const command_address = operand(high & 255, low);
        try t.expect(command_address >= owner.config.address + 4096 and command_address + 68 <= owner.config.address + 8192);
        const offset: usize = @intCast(command_address - owner.config.address);
        for (&decoded, 0..) |*v, i| v.* = word(&command_view, offset + i * 4);
        const headers = [_]u32{0x20010000,0x20040100,0x20010106,0x200100c0,0x20030090,0x200100c0};
        for ([_]usize{0,2,7,9,11,15}, headers) |at, expected| try t.expect(decoded[at] == expected);
        try t.expect(decoded[1] == owner.config.copy_class and decoded[10] == 0x04000182 and decoded[16] == 0xc);
        try t.expect(operand(decoded[12], decoded[13]) == owner.config.address + 8704 and decoded[14] == owner.ring.issued);
        // GPGet means fetch only. It cannot authorize completion or reuse.
        std.mem.writeInt(u32, fifo.slots[0].data[8192 + 0x88..][0..4], put, .little);
        fetched = true;
    }
    pub fn execute() !void {
        try t.expect(active and fetched and !executed);
        const source = try data(operand(decoded[3], decoded[4]), decoded[8]);
        const target = try data(operand(decoded[5], decoded[6]), decoded[8]);
        @memcpy(target, source); executed = true;
    }
    pub fn signal() !void {
        try t.expect(active and executed and !signaled);
        // SYS-scope release makes preceding CE data visible before the point.
        host[0] = gpu_data[0]; host[1] = gpu_data[1];
        std.mem.writeInt(u32, fifo.slots[0].data[8704..8708], decoded[14], .little);
        signaled = true;
    }
    pub fn heldReferences() usize { var n: usize = 0; for (references) |entry| if (entry.active) { n += 1; }; return n; }
    pub fn closeApp() void { std.debug.assert(!active); app_reference = false; native.slots[native_index].imported = heldNative(); }
};
