// Host-only CE executor. Command fetch, GPU data and CPU visibility are separate
// views; production submits the encoded methods and never calls this model.
// GOB sector layout reference: Mesa nil/tiling.rs and nil/copy.rs.
// Copyright (c) 2024 Valve Corp. and Collabora, Ltd.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
const std = @import("std");
const a = @import("r4os").abi;
const t = std.testing;
const native = @import("gsp_vram_test_model.zig").Model;
const fifo = @import("gsp_fifo_test_model.zig").Model;
pub const Model = struct {
    pub const length = 12288;
    pub const binding: a.GfxBackendBinding = .{ .adapter_id = 0x01000000, .milestone = 1, .device_generation = 7, .reset_generation = 11 };
    const Reference = struct { active: bool = false, buffer: a.GfxBufferHandle = .{}, mapping_only: bool = true };
    var references: [16]Reference = @splat(.{});
    var original: a.GfxDriverMemoryApi = .{};
    pub var host: [2][length]u8 = undefined;
    var gpu_data: [2][length]u8 = undefined;
    pub var vram_data: [65536]u8 = undefined;
    pub var replacement_vram: [65536]u8 = undefined;
    var extra_vram: [native.slots.len][65536]u8 = undefined;
    var replacement_native: ?usize = null;
    var replacement_descriptor: ?a.GfxBufferDescriptor = null;
    pub var replacement_lent = false;
    pub var borrowed_releases: usize = 0;
    var initial_index: usize = 0;
    var command_view: [length]u8 = undefined;
    var command_slot: usize = 0;
    pub var dma: [2]a.GfxDeviceLease = @splat(.{});
    pub var gpu: [2]a.GfxDeviceLease = @splat(.{});
    pub var job: a.GfxDriverJob = .{};
    pub var queued = false;
    pub var active = false;
    pub var completed: usize = 0;
    pub var result: u32 = 0;
    pub var lost = false;
    pub var unregisters: usize = 0;
    pub var presentation_wakes: usize = 0;
    pub var initial_read: a.GfxDeviceLease = .{};
    pub var reject_initial_read = false;
    pub var reject_initial_release = false;
    pub var reject_resource = false;
    pub var native_index: usize = 0;
    var app_reference = false;
    var decoded: [37]u32 = undefined;
    const Block = struct { width: u32, height: u32, x: u32, y: u32, log2_gobs: u5 };
    var blocks: [2]?Block = .{ null, null };
    var decoded_count: u32 = 0;
    var present_mode = false;
    var product_mode = false;
    var render_mode = false;
    pub var render_operations: u64 = 13;
    pub var shadow_cpu = false;
    pub var shadow_creates: usize = 0;
    var shadow_descriptor: a.GfxBufferDescriptor = .{};
    var shadow_live = false;
    var registration: ?a.GfxBackendRegistration = null;
    var fetched = false;
    var executed = false;
    var signaled = false;
    pub fn install(table: *a.DriverApi, index: usize) void {
        std.debug.assert(table.gfx_memory_query.?(&original) == a.gfx_buffer_result_ok);
        table.gfx_memory_query = memory; table.gfx_queue_query = queue;
        references = @splat(.{}); dma = @splat(.{}); gpu = @splat(.{}); queued = false; active = false;
        completed = 0; result = 0; lost = false; unregisters = 0; reject_resource = false; native_index = index; fetched = false; executed = false; signaled = false;
        present_mode = false; product_mode = false; render_mode = false; render_operations = 13; shadow_cpu = false; shadow_creates = 0;
        shadow_live = false; registration = null; decoded_count = 0; presentation_wakes = 0;
        initial_read = .{}; reject_initial_read = false; reject_initial_release = false;
        replacement_native = null; replacement_descriptor = null; replacement_lent = false; borrowed_releases = 0; initial_index = 0;
        app_reference = true; native.slots[index].imported = true; // Separate app alias, independent of the allocator's producer reference.
        for (0..2) |i| { @memset(&host[i], 0xa5); @memset(&gpu_data[i], 0x5a); }
        @memset(&vram_data, 0xcc);
        @memset(&replacement_vram, 0xcc);
        for (&extra_vram) |*bytes| @memset(bytes, 0xcc);
    }
    pub fn installPresentation(table: *a.DriverApi, index: usize, width: u32, height: u32) void {
        install(table, index); present_mode = true; shadow_live = true;
        shadow_descriptor = .{ .byte_length = @as(u64, width) * height * 4, .alignment = 4096,
            .width = width, .height = height, .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1,
            .plane_pitches = .{ @as(u64, width) * 4, 0, 0, 0 }, .usage = 39 };
    }
    pub fn installProduct(table: *a.DriverApi, index: usize) void {
        const previous = native.slots[index].imported;
        install(table, index);
        native.slots[index].imported = previous;
        app_reference = false;
        present_mode = true; product_mode = true;
    }
    pub fn installRender(table: *a.DriverApi, index: usize) void {
        install(table, index); render_mode = true;
        closeApp();
    }
    pub fn enqueueRender(target: usize, source: ?usize, command: a.GfxRenderCommand, deadline: u64) void {
        enqueue(false);
        job.operation = a.gfx_queue_operation_render; job.deadline_ns = deadline;
        job.source_buffer = if (source) |i| native.slots[i].reservation.buffer else .{};
        job.target_buffer = native.slots[target].reservation.buffer;
        job.source_offset = 0; job.target_offset = 0; job.byte_length = 0;
        job.render = command;
    }
    pub fn observeRenderExecution() void { std.debug.assert(render_mode and active); executed = true; }
    pub fn observeRenderSemaphore() void { std.debug.assert(render_mode and active and executed); signaled = true; }
    pub fn shadowReference() a.GfxBufferHandle { return .{ .id = 1499, .generation = 951 }; }
    fn replacementReference() a.GfxBufferHandle { return .{ .id = 1497, .generation = 951 }; }
    pub fn lendReplacement(index: usize, width: u32, height: u32) a.GfxBufferReference {
        std.debug.assert(product_mode and !replacement_lent and index != native_index and
            dma[1].lease.id == 0 and gpu[1].lease.id == 0 and @as(u64, width) * height * 4 <= length);
        for (references) |entry| std.debug.assert(!entry.active or !std.meta.eql(entry.buffer, sys(1)));
        replacement_native = index; replacement_lent = true;
        replacement_descriptor = .{ .byte_length = @as(u64, width) * height * 4, .alignment = 4096,
            .width = width, .height = height, .format = a.gfx_buffer_format_xrgb8888, .plane_count = 1,
            .plane_pitches = .{ @as(u64, width) * 4, 0, 0, 0 }, .usage = 38 };
        @memset(&replacement_vram, 0xcc);
        return .{ .buffer = sys(1), .reference = replacementReference() };
    }
    fn descriptor(index: usize) a.GfxBufferDescriptor { return if (index == 0) shadow_descriptor else replacement_descriptor.?; }
    pub fn replacementReferences() usize {
        var n: usize = 0;
        for (references) |entry| if (entry.active and std.meta.eql(entry.buffer, sys(1))) { n += 1; };
        return n;
    }
    pub fn closeShadow() void { shadow_live = false; }
    pub fn wakePresentation(raw: usize) i32 {
        const target: *@import("gsp_device.zig").Device = @ptrFromInt(raw);
        std.debug.assert(target.running.presentation.?.pending);
        presentation_wakes += 1; return 0;
    }
    pub fn enqueuePresent(x: u32, y: u32, width: u32, height: u32) !void {
        return enqueuePresentFrom(0, x, y, width, height);
    }
    pub fn enqueuePresentFrom(index: usize, x: u32, y: u32, width: u32, height: u32) !void {
        enqueue(false);
        job.operation = a.gfx_queue_operation_upload;
        job.source_buffer = sys(index); job.target_buffer = .{}; job.target_offset = 0;
        const pitch = descriptor(index).plane_pitches[0];
        job.source_offset = y * pitch + x * 4; job.byte_length = (height - 1) * pitch + width * 4;
        const registered = registration orelse return error.State;
        const callback: *const fn (usize) callconv(.c) i32 = @ptrFromInt(registered.notify_callback);
        try t.expect(callback(@intCast(registered.context)) == 0);
    }
    pub fn address(index: usize) u64 { return 0x80000000 + index * 0x100000; }
    fn sys(index: usize) a.GfxBufferHandle { return .{ .id = @intCast(1101 + index), .generation = 901 }; }
    fn ref(index: usize) a.GfxBufferHandle { return .{ .id = @intCast(1501 + index), .generation = 951 }; }
    fn select(input: a.GfxBufferHandle) ?usize { for (0..references.len) |i| if (std.meta.eql(input, ref(i))) return i; return null; }
    fn system(input: a.GfxBufferHandle) ?usize { for (0..2) |i| if (std.meta.eql(input, sys(i))) return i; return null; }
    fn nativeSlot(buffer: a.GfxBufferHandle) ?usize {
        for (&native.slots, 0..) |*slot, i| if (slot.live and std.meta.eql(buffer, slot.reservation.buffer)) return i;
        return null;
    }
    fn queuedNative(index: usize) bool {
        return active and (nativeSlot(job.source_buffer) == index or nativeSlot(job.target_buffer) == index);
    }
    fn heldNative() bool {
        return heldNativeAt(native_index);
    }
    fn heldNativeAt(index: usize) bool {
        if (index == native_index and present_mode) return true; // Display Use outlives queue jobs.
        if (queuedNative(index) or (index == native_index and app_reference)) return true;
        for (references) |entry| if (entry.active and std.meta.eql(entry.buffer, native.slots[index].reservation.buffer)) return true;
        return false;
    }
    pub fn enqueue(readback: bool) void {
        std.debug.assert(!active and !queued and !lost);
        const point = completed + 1;
        job = .{ .fence = .{ .slot = 1, .adapter_id = binding.adapter_id, .timeline = 19, .point = point,
                .device_generation = binding.device_generation, .reset_generation = binding.reset_generation },
            .operation = a.gfx_queue_operation_copy,
            .source_buffer = if (readback) native.slots[native_index].reservation.buffer else sys(0),
            .target_buffer = if (readback) sys(1) else native.slots[native_index].reservation.buffer,
            .source_offset = if (readback) 129 else 33, .target_offset = if (readback) 71 else 129, .byte_length = 4091 };
        queued = true; fetched = false; executed = false; signaled = false;
    }
    pub fn enqueueRows(source: ?usize, target: ?usize, source_offset: u64, target_offset: u64, bytes: u32, rows: u32, source_pitch: u64, target_pitch: u64) void {
        enqueue(false);
        job.operation = a.gfx_queue_operation_copy_rows;
        job.source_buffer = if (source) |i| native.slots[i].reservation.buffer else sys(0);
        job.target_buffer = if (target) |i| native.slots[i].reservation.buffer else sys(1);
        job.source_offset = source_offset; job.target_offset = target_offset; job.byte_length = bytes;
        job.row_count = rows; job.source_pitch = source_pitch; job.target_pitch = target_pitch;
    }
    fn queue(out: *a.GfxDriverQueueApi) callconv(.c) i32 { out.* = .{ .size = if (product_mode or render_mode) @sizeOf(a.GfxDriverQueueApi) else 64,
        .register_backend = @intFromPtr(&register), .register_profile = if (product_mode) @intFromPtr(&registerProfile) else 0,
        .update_operations = if (render_mode) @intFromPtr(&updateOperations) else 0,
        .unregister_backend = @intFromPtr(&unregister), .take = @intFromPtr(&take), .retain_resource = @intFromPtr(&retain), .complete = @intFromPtr(&complete) }; return a.gfx_queue_ok; }
    fn updateOperations(input: *const a.GfxBackendBinding, operations: u64) callconv(.c) i32 {
        std.debug.assert(render_mode and std.meta.eql(input.*, binding) and operations == 29);
        render_operations = operations; return a.gfx_queue_ok;
    }
    fn registerProfile(input: *const a.GfxBackendRegistration, profile: *const a.GfxBackendProfile, out: *a.GfxBackendBinding) callconv(.c) i32 {
        const nv = @import("r4nv_binding");
        std.debug.assert(product_mode and profile.version == 1 and profile.size == 96 and profile.data_bytes == 32 and
            profile.interface_id_lo == nv.backend_v1_header.interface_id_lo and profile.interface_id_hi == nv.backend_v1_header.interface_id_hi and profile.revision == 1);
        const details = std.mem.bytesToValue(nv.R4NvDriverProfile, profile.data[0..32]);
        std.debug.assert(details.version == 1 and details.size == 32 and details.vendor_id == 0x10de and
            (details.copy_class == 0xc6b5 or details.copy_class == 0xc7b5) and details.rm_release == nv.rm_release and details.command_abi == nv.command_abi and
            details.reserved0 == 0 and details.reserved1 == 0);
        for (profile.data[32..]) |byte| std.debug.assert(byte == 0);
        return register(input, out);
    }
    fn register(input: *const a.GfxBackendRegistration, out: *a.GfxBackendBinding) callconv(.c) i32 {
        std.debug.assert(present_mode and registration == null and input.adapter_id == binding.adapter_id and
            input.milestone == binding.milestone and input.notify_callback != 0 and input.context != 0);
        registration = input.*; out.* = binding; return a.gfx_queue_ok;
    }
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
        gpu_data[0] = host[0]; gpu_data[1] = host[1];
        for (&native.slots, 0..) |*slot, i| if (queuedNative(i)) { slot.imported = true; };
        return a.gfx_queue_ok;
    }
    fn retain(input: *const a.GfxFence, which: u32, out: *a.GfxBufferReference) callconv(.c) i32 {
        if (!active or !std.meta.eql(input.*, job.fence) or which >= 2) return a.gfx_queue_error_invalid;
        if (present_mode and which != 0) return a.gfx_queue_error_invalid;
        if (reject_resource and which == 1) return a.gfx_queue_error_capacity;
        for (&references, 0..) |*entry, i| if (!entry.active) {
            entry.* = .{ .active = true, .buffer = if (which == 0) job.source_buffer else job.target_buffer };
            out.* = .{ .reference = ref(i), .buffer = entry.buffer, .flags = a.gfx_buffer_reference_mapping_only }; return a.gfx_queue_ok;
        };
        return a.gfx_queue_error_capacity;
    }
    fn complete(input: *const a.GfxFence, status: u32, quiesced: u32) callconv(.c) i32 {
        std.debug.assert(active and !lost and std.meta.eql(input.*, job.fence) and quiesced == 1);
        std.debug.assert(status == a.gfx_queue_result_complete or status == a.gfx_queue_result_failed or status == a.gfx_queue_result_cancelled);
        if (status == a.gfx_queue_result_complete) std.debug.assert(signaled and executed);
        active = false; result = status; completed += 1;
        for ([_]a.GfxBufferHandle{ job.source_buffer, job.target_buffer }) |buffer| if (nativeSlot(buffer)) |i| {
            native.slots[i].imported = heldNativeAt(i);
        };
        return a.gfx_queue_ok;
    }
    fn memory(out: *a.GfxDriverMemoryApi) callconv(.c) i32 {
        out.* = original;
        out.buffer_import = @intFromPtr(&importBuffer);
        out.buffer_describe = @intFromPtr(&describe); out.buffer_release = @intFromPtr(&drop);
        out.device_acquire = @intFromPtr(&acquire); out.device_segment = @intFromPtr(&segment); out.device_release = @intFromPtr(&releaseDevice);
        if (product_mode) {
            out.buffer_create = @intFromPtr(&createShadow);
            out.buffer_map = @intFromPtr(&mapShadow); out.buffer_unmap = @intFromPtr(&unmapShadow);
        }
        return a.gfx_buffer_result_ok;
    }
    fn createShadow(d: *const a.GfxBufferDescriptor, out: *a.GfxBufferReference) callconv(.c) i32 {
        if (d.format != a.gfx_buffer_format_xrgb8888) {
            const call: *const fn (*const a.GfxBufferDescriptor, *a.GfxBufferReference) callconv(.c) i32 = @ptrFromInt(original.buffer_create);
            return call(d, out);
        }
        std.debug.assert(!shadow_live and d.location == 0 and d.byte_length <= length and (d.usage == 7 or d.usage == 39) and d.plane_count == 1);
        for (references) |entry| std.debug.assert(!entry.active or !std.meta.eql(entry.buffer, sys(0)));
        shadow_descriptor = d.*; shadow_live = true; shadow_creates += 1;
        out.* = .{ .buffer = sys(0), .reference = shadowReference() };
        return a.gfx_buffer_result_ok;
    }
    fn mapShadow(input: *const a.GfxBufferHandle, access: u32, offset: u64, bytes: u64, out: *a.GfxBufferMap) callconv(.c) i32 {
        if (!std.meta.eql(input.*, shadowReference())) {
            const call: *const fn (*const a.GfxBufferHandle, u32, u64, u64, *a.GfxBufferMap) callconv(.c) i32 = @ptrFromInt(original.buffer_map);
            return call(input, access, offset, bytes, out);
        }
        std.debug.assert(shadow_live and !shadow_cpu and initial_read.lease.id == 0 and !active and access == 1 and offset == 0 and bytes == shadow_descriptor.byte_length);
        shadow_cpu = true;
        out.* = .{ .lease = .{ .id = 1498, .generation = 951 }, .cpu_address = @intFromPtr(&host[0]), .byte_length = bytes };
        return a.gfx_buffer_result_ok;
    }
    fn unmapShadow(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        if (input.id != 1498 or input.generation != 951) {
            const call: *const fn (*const a.GfxBufferHandle) callconv(.c) i32 = @ptrFromInt(original.buffer_unmap);
            return call(input);
        }
        std.debug.assert(shadow_live and shadow_cpu); shadow_cpu = false; return a.gfx_buffer_result_ok;
    }
    fn describe(input: *const a.GfxBufferHandle, out: *a.GfxBufferDescriptor) callconv(.c) i32 {
        if (replacement_lent and std.meta.eql(input.*, replacementReference())) {
            out.* = replacement_descriptor.?; return a.gfx_buffer_result_ok;
        }
        if (present_mode and std.meta.eql(input.*, shadowReference())) {
            std.debug.assert(shadow_live); out.* = shadow_descriptor; return a.gfx_buffer_result_ok;
        }
        const index = select(input.*) orelse { const call: *const fn (*const a.GfxBufferHandle, *a.GfxBufferDescriptor) callconv(.c) i32 = @ptrFromInt(original.buffer_describe); return call(input, out); };
        const entry = references[index]; std.debug.assert(entry.active);
        out.* = if (present_mode and system(entry.buffer) != null) descriptor(system(entry.buffer).?) else if (system(entry.buffer) != null) .{ .byte_length = length - 5, .alignment = 4096, .usage = 15 }
            else native.slots[nativeSlot(entry.buffer).?].descriptor;
        return a.gfx_buffer_result_ok;
    }
    fn importBuffer(input: *const a.GfxBufferHandle, out: *a.GfxBufferReference) callconv(.c) i32 {
        const own = if (select(input.*)) |index| references[index].active and !references[index].mapping_only and
            system(references[index].buffer) != null else false;
        const replacement = replacement_lent and std.meta.eql(input.*, replacementReference());
        if (!present_mode or (!std.meta.eql(input.*, shadowReference()) and !own and !replacement)) {
            const call: *const fn (*const a.GfxBufferHandle, *a.GfxBufferReference) callconv(.c) i32 = @ptrFromInt(original.buffer_import); return call(input, out);
        }
        std.debug.assert(shadow_live or own or replacement);
        const buffer = if (own) references[select(input.*).?].buffer else sys(@intFromBool(replacement));
        for (&references, 0..) |*entry, i| if (!entry.active) {
            entry.* = .{ .active = true, .buffer = buffer, .mapping_only = false };
            out.* = .{ .reference = ref(i), .buffer = entry.buffer }; return a.gfx_buffer_result_ok;
        };
        return a.gfx_buffer_error_capacity;
    }
    fn drop(input: *const a.GfxBufferHandle) callconv(.c) i32 {
        if (std.meta.eql(input.*, replacementReference())) {
            borrowed_releases += 1; return a.gfx_buffer_error_invalid;
        }
        if (product_mode and std.meta.eql(input.*, shadowReference())) {
            std.debug.assert(shadow_live and !shadow_cpu); shadow_live = false; return a.gfx_buffer_result_ok;
        }
        const index = select(input.*) orelse { const call: *const fn (*const a.GfxBufferHandle) callconv(.c) i32 = @ptrFromInt(original.buffer_release); return call(input); };
        std.debug.assert(references[index].active);
        const buffer = references[index].buffer; references[index].active = false;
        if (nativeSlot(buffer)) |slot| native.slots[slot].imported = heldNativeAt(slot);
        return a.gfx_buffer_result_ok;
    }
    fn acquire(input: *const a.GfxBufferHandle, request: *const a.GfxDeviceRequest, out: *a.GfxDeviceLease) callconv(.c) i32 {
        const index = select(input.*) orelse {
            const call: *const fn (*const a.GfxBufferHandle, *const a.GfxDeviceRequest, *a.GfxDeviceLease) callconv(.c) i32 = @ptrFromInt(original.device_acquire);
            return call(input, request, out);
        }; const entry = references[index]; const i = system(entry.buffer).?;
        if (request.access == 0) {
            std.debug.assert(present_mode and !shadow_cpu and entry.active and !entry.mapping_only and initial_read.lease.id == 0 and
                (!queued or active) and request.byte_offset == 0 and request.byte_length == descriptor(i).byte_length and
                dma[i].lease.id != 0 and request.gpu_virtual_address == address(i) and request.address_space == 1);
            if (reject_initial_read) return a.gfx_buffer_error_busy;
            out.* = .{ .lease = .{ .id = 1799, .generation = 991 }, .byte_length = request.byte_length,
                .gpu_virtual_address = request.gpu_virtual_address, .device_generation = request.device_generation, .adapter_id = request.adapter_id,
                .driver_owner = 7, .access = 0, .address_space = 1, .dma_mask = request.dma_mask };
            initial_read = out.*; initial_index = i; gpu_data[i] = host[i]; fetched = false; executed = false; signaled = false;
            return a.gfx_buffer_result_ok;
        }
        const mapped_bytes = if (present_mode)
            (if (entry.mapping_only) (descriptor(i).byte_length + 4095) & ~@as(u64, 4095) else descriptor(i).byte_length) else length;
        std.debug.assert(entry.active and request.byte_offset == 0 and request.byte_length == mapped_bytes);
        const virtual = request.access == 3;
        if (virtual) std.debug.assert(dma[i].lease.id != 0 and gpu[i].lease.id == 0 and request.gpu_virtual_address == address(i) and request.address_space == 1)
        else std.debug.assert(dma[i].lease.id == 0 and request.access == 4 and request.address_space == 0);
        out.* = .{ .lease = .{ .id = @intCast(1701 + i * 2 + @intFromBool(virtual)), .generation = 991 }, .byte_length = mapped_bytes,
            .gpu_virtual_address = request.gpu_virtual_address, .device_generation = request.device_generation, .adapter_id = request.adapter_id,
            .driver_owner = 7, .access = request.access, .address_space = request.address_space, .dma_mask = request.dma_mask };
        if (virtual) gpu[i] = out.* else dma[i] = out.*;
        return a.gfx_buffer_result_ok;
    }
    fn segment(input: *const a.GfxDeviceLease, offset: u64, out: *a.GfxDmaSegment) callconv(.c) i32 {
        if (input.lease.id < 1701 or input.lease.id > 1704) {
            const call: *const fn (*const a.GfxDeviceLease, u64, *a.GfxDmaSegment) callconv(.c) i32 = @ptrFromInt(original.device_segment);
            return call(input, offset, out);
        }
        const i = (input.lease.id - 1701) / 2;
        std.debug.assert(std.meta.eql(input.*, dma[i]) and offset < input.byte_length and offset & 4095 == 0);
        const bytes = @min(@as(u64, 4096), input.byte_length - offset);
        out.* = .{ .dma_address = 0x6000000000 + @as(u64, i) * 0x100000 + offset * 2, .byte_length = bytes, .next_offset = offset + bytes };
        return a.gfx_buffer_result_ok;
    }
    fn releaseDevice(input: *const a.GfxDeviceLease, quiesced: u32) callconv(.c) i32 {
        if (input.lease.id != 1799 and (input.lease.id < 1701 or input.lease.id > 1704)) {
            const call: *const fn (*const a.GfxDeviceLease, u32) callconv(.c) i32 = @ptrFromInt(original.device_release);
            return call(input, quiesced);
        }
        if (input.access == 0) {
            std.debug.assert(std.meta.eql(input.*, initial_read) and quiesced == 1 and (!fetched or signaled));
            if (reject_initial_release) return a.gfx_buffer_error_busy;
            initial_read = .{}; return a.gfx_buffer_result_ok;
        }
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
            if (bytes > length - offset or (gpu[i].lease.id == 0 and
                !(present_mode and dma[i].lease.id != 0 and (active or (initial_read.lease.id != 0 and initial_index == i))))) return error.GpuAddress;
            return gpu_data[i][offset..][0..bytes];
        };
        if (replacement_native) |index| {
            const start = native.address(index);
            if (address_value >= start and address_value - start < replacement_vram.len) {
                const offset: usize = @intCast(address_value - start);
                if (bytes > replacement_vram.len - offset or !native.slots[index].live or native.slots[index].gpu.lease.id == 0) return error.GpuAddress;
                return replacement_vram[offset..][0..bytes];
            }
        }
        for (0..native.slots.len) |index| {
            const start = native.address(index);
            if (address_value < start or address_value - start >= vram_data.len) continue;
            const offset: usize = @intCast(address_value - start);
            if (bytes > vram_data.len - offset or !native.slots[index].live or
                (native.slots[index].gpu.lease.id == 0 and !(!present_mode and queuedNative(index)))) return error.GpuAddress;
            return (if (index == native_index) &vram_data else &extra_vram[index])[offset..][0..bytes];
        }
        return error.GpuAddress;
    }
    pub fn imageBytes(index: usize) []u8 {
        return if (replacement_native == index) &replacement_vram else if (index == native_index) &vram_data else &extra_vram[index];
    }
    pub fn fetch(owner: *@import("gsp_fifo.zig").Owner, mmio: []const u8) !void {
        try t.expect((active or initial_read.lease.id != 0) and !fetched and owner.ring.pending == null);
        try t.expect(word(mmio, 0xbb0090) == owner.work_submit_token.?);
        // The device observes commands only at the published doorbell boundary.
        command_slot = for (&fifo.slots,0..) |_, i| {
            if (fifo.address(i) == owner.config.address) break i;
        } else return error.CommandStorage;
        command_view = fifo.slots[command_slot].data;
        const put = word(&command_view, 8192 + 0x8c);
        try t.expect(put == owner.ring.put and put < 512);
        const index = (put + 511) % 512;
        const low = word(&command_view, index * 8); const high = word(&command_view, index * 8 + 4);
        decoded_count = high >> 10;
        try t.expect((decoded_count == 17 or decoded_count == 19 or decoded_count == 28 or decoded_count == 37) and high & 0x300 == 0 and low & 3 == 0);
        const command_address = operand(high & 255, low);
        try t.expect(command_address >= owner.config.address + 4096 and command_address + decoded_count * 4 <= owner.config.address + 8192);
        const offset: usize = @intCast(command_address - owner.config.address);
        for (decoded[0..decoded_count], 0..) |*v, i| v.* = word(&command_view, offset + i * 4);
        blocks = .{ null, null };
        if (decoded_count != 17) {
            try t.expect(decoded[0] == 0x20010000 and decoded[1] == owner.config.object_class and decoded[2] == 0x20080100);
            var at: usize = 11;
            while (at + 9 < decoded_count and decoded[at] != 0x200100c0) : (at += 9) {
                const i: usize = switch (decoded[at]) { 0x200501ca => 0, 0x200501c3 => 1, else => return error.BlockMethods };
                try t.expect(blocks[i] == null and decoded[at + 1] & ~@as(u32, 0x70) == 0x1000 and decoded[at + 4] == 1 and decoded[at + 5] == 0 and
                    decoded[at + 6] == @as(u32, if (i == 0) 0x200201d1 else 0x200201d3));
                const block: Block = .{ .width = decoded[at + 2], .height = decoded[at + 3], .log2_gobs = @intCast((decoded[at + 1] >> 4) & 7),
                    .x = decoded[at + 7], .y = decoded[at + 8] };
                try t.expect(block.log2_gobs <= 5 and block.width % 64 == 0 and block.x + decoded[9] <= block.width and block.y + decoded[10] <= block.height);
                blocks[i] = block;
            }
            const launch: u32 = 0x202 | @as(u32, if (owner.config.object_class == 0xc7b5) 1 << 26 else 0) |
                @as(u32, if (blocks[0] == null) 128 else 0) | @as(u32, if (blocks[1] == null) 256 else 0);
            try t.expect(at + 8 == decoded_count and decoded[at] == 0x200100c0 and decoded[at + 1] == launch and decoded[at + 2] == 0x20030090 and
                decoded[at + 6] == 0x200100c0 and decoded[at + 7] == 12 and
                operand(decoded[at + 3], decoded[at + 4]) == owner.config.address + 8704 and decoded[at + 5] == owner.ring.issued);
        } else {
        const headers = [_]u32{0x20010000,0x20040100,0x20010106,0x200100c0,0x20030090,0x200100c0};
        for ([_]usize{0,2,7,9,11,15}, headers) |at, expected| try t.expect(decoded[at] == expected);
        try t.expect(decoded[1] == owner.config.object_class and decoded[10] == 0x04000182 and decoded[16] == 0xc);
        try t.expect(operand(decoded[12], decoded[13]) == owner.config.address + 8704 and decoded[14] == owner.ring.issued);
        }
        // GPGet means fetch only. It cannot authorize completion or reuse.
        std.mem.writeInt(u32, fifo.slots[command_slot].data[8192 + 0x88..][0..4], put, .little);
        fetched = true;
    }
    pub fn execute() !void {
        try t.expect((active or initial_read.lease.id != 0) and fetched and !executed);
        if (decoded_count != 17) {
            for (0..decoded[10]) |y| {
                for (0..decoded[9]) |x| {
                    const src = if (blocks[0]) |b| tileOffset(b, @intCast(x), @intCast(y)) else y * decoded[7] + x;
                    const dst = if (blocks[1]) |b| tileOffset(b, @intCast(x), @intCast(y)) else y * decoded[8] + x;
                    const source = try data(operand(decoded[3], decoded[4]) + src, 1);
                    const target = try data(operand(decoded[5], decoded[6]) + dst, 1);
                    target[0] = source[0];
                }
            }
        } else {
            const source = try data(operand(decoded[3], decoded[4]), decoded[8]);
            const target = try data(operand(decoded[5], decoded[6]), decoded[8]);
            @memcpy(target, source);
        }
        executed = true;
    }
    pub fn signal() !void {
        try t.expect((active or initial_read.lease.id != 0) and executed and !signaled);
        // SYS-scope release makes preceding CE data visible before the point.
        host[0] = gpu_data[0]; host[1] = gpu_data[1];
        std.mem.writeInt(u32, fifo.slots[command_slot].data[8704..8708], decoded[decoded_count - 3], .little);
        signaled = true;
    }
    pub fn heldReferences() usize { var n: usize = 0; for (references) |entry| if (entry.active) { n += 1; }; return n; }
    // TuringColor2D: the documented 4x4 sector grid, independent of the
    // production CE encoder (which never interprets individual pixel bytes).
    fn tileOffset(block: Block, column: u32, row: u32) u64 {
        const x: u64 = block.x + column; const y: u64 = block.y + row;
        const height = @as(u64, 8) << block.log2_gobs;
        const sectors = [4][4]u16{ .{ 0, 2, 8, 10 }, .{ 1, 3, 9, 11 }, .{ 4, 6, 12, 14 }, .{ 5, 7, 13, 15 } };
        return (y / height) * block.width * height + (x / 64) * 64 * height + ((y % height) / 8) * 512 +
            sectors[(y % 8) / 2][(x % 64) / 16] * 32 + (y % 2) * 16 + x % 16;
    }
    pub fn closeApp() void { std.debug.assert(!active); app_reference = false; native.slots[native_index].imported = heldNative(); }
};
