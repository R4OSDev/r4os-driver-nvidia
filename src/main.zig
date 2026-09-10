const std = @import("std");
const r4os = @import("r4os");
const identity = @import("identity.zig");
const firmware_resources = @import("firmware_resources.zig");
const firmware = @import("firmware.zig");
const firmware_storage = @import("firmware_storage.zig");
const rm_heap = @import("rm_heap.zig");
const rm_clock = @import("rm_clock.zig");
const runtime_probe = @import("runtime_probe.zig");
const thread_probe = @import("thread_probe.zig");
const semaphore_probe = @import("semaphore_probe.zig");
const a = r4os.abi;
var driver_api: ?*const a.DriverApi = null;
var window: a.GfxMmioWindow = .{};
var mapping_cleanup_needed = false;
var firmware_cpu: firmware_storage.Storage = .{};
var checking_runtime = false;

comptime {
    asm (r4os.r4dev.driverEntriesAsm("nvidia_init", "nvidia_shutdown"));
}

pub export fn nvidia_init(api: *const a.DriverApi) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    if (!ctx.apiCompatible() or driver_api != null) return -1;
    driver_api = api;
    rm_heap.bind(&ctx);
    rm_clock.bind(&ctx);
    const mode = std.mem.span(ctx.getOption("NVIDIA", "mode"));
    const check_firmware = std.ascii.eqlIgnoreCase(mode, "firmware-check");
    checking_runtime = std.ascii.eqlIgnoreCase(mode, "runtime-check");
    if (mode.len != 0 and !std.ascii.eqlIgnoreCase(mode, "passive") and !check_firmware and !checking_runtime) {
        ctx.logError("NVIDIA bind: rejected reason=unsupported-mode native-writes=disabled");
        return -2;
    }
    if (ctx.resources()) |resources| {
        const now = resources.nowNs();
        const deadline = std.math.add(u64, now, 2 * std.time.ns_per_s) catch return -6;
        const generation = firmware_resources.validateLock(resources, deadline) catch |err| {
            log("NVIDIA resource: lock=rejected reason={s} native-writes=disabled fallback=preserved", .{@errorName(err)});
            return -6;
        };
        log("NVIDIA resource: lock=verified bytes={d} module-generation={d} source=loaded-r4d native-writes=disabled", .{ firmware_resources.lock_bytes.len, generation });
    } else {
        ctx.logInfo("NVIDIA resource: unavailable firmware-loading=disabled passive-probe=available");
        if (check_firmware) return -6;
    }
    if (checking_runtime) {
        if (!semaphore_probe.start(&ctx) or !thread_probe.start(&ctx) or !runtime_probe.start(&ctx) or !thread_probe.prepareClose(&ctx) or !semaphore_probe.prepareClose(&ctx)) {
            ctx.logError("NVIDIA runtime-check: FAILED phase=cpu-memory native-writes=disabled");
            return -9;
        }
        ctx.logInfo("NVIDIA runtime-check: OK result=diagnostic-init-stop native-writes=disabled fallback=preserved");
        return -8;
    }
    if (check_firmware and !checkFirmware(&ctx)) return -7;
    var devices: [8]a.PciDeviceInfo = undefined;
    var audio: [32]identity.Pci = undefined;
    var count: usize = 0;
    var audio_count: usize = 0;
    const inventory_count = ctx.pciDeviceCount();
    if (inventory_count > 4096) return -3;
    // One pass over the kernel's immutable inventory, not PCI probing loops.
    // The loader already holds this module's DriverApi owner throughout init.
    for (0..inventory_count) |index| {
        var info: a.PciDeviceInfo = .{};
        if (ctx.pciDeviceAt(@intCast(index), &info) != 0) return -3;
        const pci = pciIdentity(info);
        if (identity.isDisplay(pci)) {
            if (count == devices.len) return -3;
            devices[count] = info;
            count += 1;
        }
        if (pci.vendor_id == 0x10de and pci.class_code == 4 and pci.subclass == 3) {
            if (audio_count == audio.len) return -3;
            audio[audio_count] = pci;
            audio_count += 1;
        }
    }
    if (count == 0) {
        ctx.logInfo("NVIDIA bind: absent inventory=canonical native-writes=disabled fallback=preserved");
        return -4;
    }
    for (devices[0..count]) |info| {
        const pci = pciIdentity(info);
        var reader: ConfigReader = .{ .ctx = ctx, .info = info };
        const snapshot = identity.capture(pci, &reader) catch |err| {
            log("NVIDIA pci={x:0>2}:{x:0>2}.{x} rejected={s} native-writes=disabled", .{ pci.bus, pci.device, pci.function, @errorName(err) });
            continue;
        };
        log("NVIDIA pci={x:0>2}:{x:0>2}.{x} id=10de:{x:0>4} subsystem={x:0>4}:{x:0>4} revision={x:0>2} command={x:0>4}", .{ pci.bus, pci.device, pci.function, pci.device_id, snapshot.subsystem_vendor, snapshot.subsystem_device, snapshot.revision, snapshot.command });
        var sibling_count: usize = 0;
        for (audio[0..audio_count]) |sibling| {
            if (!identity.isHdaSibling(pci, sibling)) continue;
            sibling_count += 1;
            log("NVIDIA hda={x:0>2}:{x:0>2}.{x} id=10de:{x:0>4} role=sibling receiver=unmeasured", .{ sibling.bus, sibling.device, sibling.function, sibling.device_id });
        }
        if (sibling_count == 0) ctx.logInfo("NVIDIA hda=absent receiver=unmeasured");
        for (snapshot.bars, 0..) |bar, index| {
            log("NVIDIA bar={d} kind={s} raw={x:0>8} base={x} bytes={d} extent={s} prefetch={}", .{ index, @tagName(bar.kind), bar.raw, bar.base, bar.bytes, if (bar.bytes == 0) @as([]const u8, "unmeasured") else "rebar-current", bar.prefetchable });
        }
        log("NVIDIA irq line={d} pin={d} pm={x} msi={x} msix={x} pcie={x} rebar={x} power={d}", .{ snapshot.interrupt_line, snapshot.interrupt_pin, snapshot.caps.pm, snapshot.caps.msi, snapshot.caps.msix, snapshot.caps.pcie, snapshot.caps.rebar, if (snapshot.caps.power_state) |value| @as(u8, value) else @as(u8, 255) });
        const admission = identity.decision(&snapshot);
        log("NVIDIA admission={s} native-writes=disabled", .{@tagName(admission)});
        if (admission == .identity_words_only and !readIdentity(&ctx, &snapshot)) return -5;
        log("NVIDIA vbios=unavailable rom-base={x} rom-enabled={} reason=passive-transport-unproven board-name=unmeasured display-generation=unmeasured", .{ snapshot.rom_base, snapshot.rom_enabled });
    }
    log("NVIDIA bind: passive devices={d} resources=0 native-writes=disabled fallback=preserved", .{count});
    return 0;
}

pub export fn nvidia_shutdown() callconv(.c) i32 {
    const api = driver_api orelse return 0;
    const ctx = r4os.r4dev.DriverContext.init(api);
    if (!semaphore_probe.shutdown(&ctx)) return -1;
    if (!thread_probe.shutdown(&ctx)) return -1;
    if (!runtime_probe.shutdown(&ctx)) return -1;
    if (!firmware_cpu.close()) return -1;
    if (!releaseWindow(&ctx)) return -1;
    if (checking_runtime) {
        ctx.logInfo("NVIDIA unbind: driver-state=closed cpu-owner-cleanup=pending native-writes=disabled fallback=preserved");
    } else ctx.logInfo("NVIDIA unbind: OK resources=0 native-writes=disabled fallback=preserved");
    rm_heap.unbind();
    rm_clock.unbind();
    checking_runtime = false;
    driver_api = null;
    return 0;
}

fn checkFirmware(ctx: *const r4os.r4dev.DriverContext) bool {
    for ([_]firmware.Family{ .ga10x, .tu10x }) |family| {
        firmware_cpu.begin(ctx, family, 30 * std.time.ns_per_s) catch |err| {
            log("NVIDIA firmware: rejected family={s} phase=storage reason={s} native-writes=disabled", .{ @tagName(family), @errorName(err) });
            _ = firmware_cpu.close();
            return false;
        };
        while (firmware_cpu.ready() == null) {
            _ = firmware_cpu.step() catch |err| {
                log("NVIDIA firmware: rejected family={s} phase=read-verify reason={s} resource-status={d} native-writes=disabled", .{ @tagName(family), @errorName(err), if (firmware_cpu.reader) |reader| reader.last_status else 0 });
                _ = firmware_cpu.close();
                return false;
            };
        }
        const verified = firmware_cpu.ready().?;
        log("NVIDIA firmware: verified family={s} rm={s} bytes={d} reads={d} sha256=matched elf=valid signature-bytes={d} gpu-authentication=unverified", .{ @tagName(family), firmware.lock.rm_version, verified.container.len, firmware_cpu.reads, verified.layout.signature.bytes });
        if (!firmware_cpu.close()) {
            ctx.logError("NVIDIA firmware: cleanup=retained native-writes=disabled");
            return false;
        }
    }
    ctx.logInfo("NVIDIA firmware-check: OK containers=2 cpu-buffers=closed native-writes=disabled fallback=preserved");
    return true;
}

fn readIdentity(ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot) bool {
    const memory = ctx.memory() orelse {
        ctx.logInfo("NVIDIA chip=unmeasured reason=MMIO-contract-unavailable");
        return true;
    };
    // The sole PCI bootstrap profile uses the published PMC identity page.
    // This is a minimum register aperture, NOT a measured whole-BAR size.
    // Only the two read-only boot dwords are accessed. No assumption about
    // display-engine compatibility follows from this bootstrap mapping.
    const request = a.GfxMmioRequest{ .resource_base = snapshot.bars[0].base, .resource_bytes = 4096, .byte_length = 4096, .cache_policy = a.gfx_buffer_cache_uncached };
    // Failed maps can retain private partial mappings without a public handle.
    mapping_cleanup_needed = true;
    if (memory.mmioMap(&request, &window) != a.gfx_buffer_result_ok) {
        ctx.logInfo("NVIDIA chip=unmeasured reason=identity-map-unavailable");
        return releaseWindow(ctx);
    }
    if (window.cpu_address == 0 or window.byte_length < 8 or window.cpu_address & 3 != 0) return releaseWindow(ctx);
    const words: [*]const volatile u32 = @ptrFromInt(window.cpu_address);
    const boot0 = words[0];
    const boot1 = words[1];
    const confirm = words[0];
    if (confirm == boot0) {
        if (identity.chip(boot0, boot1)) |chip| {
            log("NVIDIA chip={s} id={x} revision={x} boot0={x:0>8} boot1={x:0>8} profile={s} native-writes=disabled", .{ chip.name, chip.id, chip.revision, boot0, boot1, chip.profile });
        } else log("NVIDIA chip=unrecognized boot0={x:0>8} boot1={x:0>8} native-writes=disabled", .{ boot0, boot1 });
    } else ctx.logInfo("NVIDIA chip=unmeasured reason=unstable-identity native-writes=disabled");
    return releaseWindow(ctx);
}

fn releaseWindow(ctx: *const r4os.r4dev.DriverContext) bool {
    if (window.handle.id == 0 and !mapping_cleanup_needed) return true;
    const memory = ctx.memory() orelse return false;
    // No DMA or callbacks were admitted. All reads from this CPU map ended.
    if (window.handle.id != 0) {
        if (memory.mmioUnmap(&window.handle, 1) != a.gfx_buffer_result_ok) return false;
        window = .{};
    }
    if (memory.collect() != a.gfx_buffer_result_ok) return false;
    mapping_cleanup_needed = false;
    return true;
}
const ConfigReader = struct {
    ctx: r4os.r4dev.DriverContext,
    info: a.PciDeviceInfo,
    pub fn read(self: *ConfigReader, offset: u16) u32 {
        return self.ctx.pciReadConfig32(self.info, offset);
    }
};
fn pciIdentity(info: a.PciDeviceInfo) identity.Pci {
    return .{ .bus_kind = info.bus_kind, .bus = info.bus, .device = info.device, .function = info.function, .vendor_id = info.vendor_id, .device_id = info.device_id, .class_code = info.class_code, .subclass = info.subclass, .prog_if = info.prog_if };
}
fn log(comptime format: []const u8, args: anytype) void {
    const ctx = r4os.r4dev.DriverContext.init(driver_api orelse return);
    var buffer: [320]u8 = undefined;
    const message = std.fmt.bufPrintZ(&buffer, format, args) catch return;
    ctx.logInfo(message.ptr);
}
