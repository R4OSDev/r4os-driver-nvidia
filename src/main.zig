const std = @import("std");
const r4os = @import("r4os");
const identity = @import("identity.zig");
const vbios = @import("vbios.zig");
const fwsec = @import("fwsec.zig");
const fwsec_prepare = @import("fwsec_prepare.zig");
const fwsec_probe = @import("fwsec_probe.zig");
const fwsec_storage = @import("fwsec_storage.zig");
const fwsec_state = @import("fwsec_state.zig");
const fwsec_state_probe = @import("fwsec_state_probe.zig");
const vbios_probe = @import("vbios_probe.zig");
const firmware_resources = @import("firmware_resources.zig");
const firmware = @import("firmware.zig");
const firmware_storage = @import("firmware_storage.zig");
const gsp_dma = @import("gsp_dma.zig");
const boot_resources = @import("boot_resources.zig");
const gsp_boot_storage = @import("gsp_boot_storage.zig");
const gsp_init = @import("gsp_init.zig");
const gsp_init_storage = @import("gsp_init_storage.zig");
const gsp_run_memory = @import("gsp_run_memory.zig");
const booter_storage = @import("booter_storage.zig");
const rm_heap = @import("rm_heap.zig");
const rm_clock = @import("rm_clock.zig");
const rm_semaphore = @import("rm_semaphore.zig");
const rm_native = @import("rm_native.zig");
const native_probe = @import("native_probe.zig");
const rm_wait = @import("rm_wait.zig");
const rm_log = @import("rm_log.zig");
const wait_probe = @import("wait_probe.zig");
const runtime_probe = @import("runtime_probe.zig");
const thread_probe = @import("thread_probe.zig");
const semaphore_probe = @import("semaphore_probe.zig");
const rm_semaphore_probe = @import("rm_semaphore_probe.zig");
const a = r4os.abi;
var driver_api: ?*const a.DriverApi = null;
var window: a.GfxMmioWindow = .{};
var mapping_cleanup_needed = false;
var firmware_cpu: firmware_storage.Storage = .{};
var gsp_image: gsp_dma.Storage = .{};
var boot_inputs: boot_resources.Inputs = .{};
var boot_storage: gsp_boot_storage.Storage = .{};
var init_storage: gsp_init_storage.Storage = .{};
var run_memory: gsp_run_memory.Lease = .{};
var native_device: @import("gsp_device.zig").Device = .{};
var native_hda: ?identity.Pci = null;
var native_work: @import("gsp_start_work.zig").Work = .{};
var firmware_logs: @import("gsp_logs.zig").Reader = .{};
var firmware_log_words: [@import("gsp_logs.zig").output_bytes]u8 = undefined;
var booters: booter_storage.Pair = .{};
var boot_vram: @import("boot_vram.zig").Capture = .{};
var boot_mapping: @import("boot_mapping.zig").Capture = .{};
var boot_context: @import("boot_context.zig").Capture = .{};
var boot_vram_lease: @import("boot_vram_lease.zig").Lease = .{};
// Bounded resident scratch: do not copy the maximum boot SG list to the stack.
var init_excluded: [gsp_init.max_excluded]gsp_init.Span = undefined;
var checking_boot = false;
var starting_gsp = false;
var starting_native = false;
var native_frame_count: u8 = 2;
var boot_checked = false;
var checking_runtime = false;
var board_rom: vbios_probe.Capture = .{};
var security_fuses: fwsec_probe.Capture = .{};
var fwsec_cpu: fwsec_storage.Storage = .{};
var fwsec_frts: fwsec_storage.Storage = .{};
var fwsec_hardware: fwsec_state_probe.Capture = .{};

comptime {
    asm (r4os.r4dev.driverEntriesAsm("nvidia_init", "nvidia_shutdown"));
}

pub export fn nvidia_init(api: *const a.DriverApi) callconv(.c) i32 {
    const ctx = r4os.r4dev.DriverContext.init(api);
    if (!ctx.apiCompatible() or driver_api != null) return -1;
    driver_api = api;
    rm_heap.bind(&ctx);
    rm_clock.bind(&ctx);
    rm_semaphore.bind(&ctx);
    rm_native.bind(&ctx);
    rm_wait.bind(&ctx);
    rm_log.bind(&ctx);
    const mode = std.mem.span(ctx.getOption("NVIDIA", "mode"));
    const check_firmware = std.ascii.eqlIgnoreCase(mode, "firmware-check");
    starting_native = std.ascii.eqlIgnoreCase(mode, "native");
    if (starting_native) {
        const buffers = std.mem.span(ctx.getOption("NVIDIA", "buffers"));
        native_frame_count = @import("gsp_native_output.zig").frameCount(buffers) catch {
            ctx.logError("NVIDIA native-output: rejected reason=buffers-must-be-2-or-3 firmware-execution=disabled");
            return -2;
        };
    }
    starting_gsp = starting_native or std.ascii.eqlIgnoreCase(mode, "gsp-start");
    checking_boot = starting_gsp or std.ascii.eqlIgnoreCase(mode, "boot-check");
    boot_checked = false;
    checking_runtime = std.ascii.eqlIgnoreCase(mode, "runtime-check");
    if (starting_gsp and ctx.apiVersion() < a.driver_api_thread_work_version) {
        ctx.logError("NVIDIA gsp-start: rejected reason=kernel-work-or-shutdown-contract firmware-execution=disabled");
        return -12;
    }
    if (mode.len != 0 and !std.ascii.eqlIgnoreCase(mode, "passive") and !check_firmware and !checking_runtime and !checking_boot) {
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
        if (check_firmware or checking_boot) return -6;
    }
    if (checking_runtime) {
        if (!wait_probe.start(&ctx) or !native_probe.start(&ctx) or !rm_semaphore_probe.start(&ctx) or !semaphore_probe.start(&ctx) or !thread_probe.start(&ctx) or !runtime_probe.start(&ctx) or !thread_probe.prepareClose(&ctx) or !semaphore_probe.prepareClose(&ctx) or !rm_semaphore_probe.prepareClose(&ctx) or !native_probe.prepareFault(&ctx)) {
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
    if (starting_gsp and count != 1) {
        ctx.logError("NVIDIA gsp-start: rejected reason=ambiguous-adapter firmware-execution=disabled");
        return -12;
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
        native_hda = null;
        for (audio[0..audio_count]) |sibling| {
            if (!identity.isHdaSibling(pci, sibling)) continue;
            sibling_count += 1;
            native_hda = sibling;
            log("NVIDIA hda={x:0>2}:{x:0>2}.{x} id=10de:{x:0>4} role=sibling receiver=unmeasured", .{ sibling.bus, sibling.device, sibling.function, sibling.device_id });
        }
        if (sibling_count == 0) ctx.logInfo("NVIDIA hda=absent receiver=unmeasured");
        if (sibling_count != 1) native_hda = null;
        for (snapshot.bars, 0..) |bar, index| {
            log("NVIDIA bar={d} kind={s} raw={x:0>8} base={x} bytes={d} extent={s} prefetch={}", .{ index, @tagName(bar.kind), bar.raw, bar.base, bar.bytes, if (bar.bytes == 0) @as([]const u8, "unmeasured") else "rebar-current", bar.prefetchable });
        }
        log("NVIDIA irq line={d} pin={d} pm={x} msi={x} msix={x} pcie={x} rebar={x} power={d}", .{ snapshot.interrupt_line, snapshot.interrupt_pin, snapshot.caps.pm, snapshot.caps.msi, snapshot.caps.msix, snapshot.caps.pcie, snapshot.caps.rebar, if (snapshot.caps.power_state) |value| @as(u8, value) else @as(u8, 255) });
        const admission = identity.decision(&snapshot);
        log("NVIDIA admission={s} native-writes=disabled", .{@tagName(admission)});
        var chip: ?identity.Chip = null;
        if (admission == .identity_words_only and !readIdentity(&ctx, &snapshot, &chip)) return -5;
        if (chip != null and vbios_probe.admitted(&snapshot, chip.?)) {
            if (!readVbios(&ctx, &snapshot, chip.?)) return -10;
        } else log("NVIDIA vbios=unavailable rom-base={x} rom-enabled={} reason=identity-or-range-unmeasured board-name=unmeasured display-generation=unmeasured", .{ snapshot.rom_base, snapshot.rom_enabled });
    }
    if (checking_boot and !boot_checked) {
        ctx.logError("NVIDIA boot-check: unavailable reason=no-admitted-preflight native-writes=disabled fallback=preserved");
        return -11;
    }
    if (starting_gsp) {
        ctx.logInfo(if (starting_native) "NVIDIA bind: gsp-start=scheduled firmware=570.144 display=held native-output=requested" else
            "NVIDIA bind: gsp-start=scheduled firmware=570.144 display=held native-output=unavailable");
    } else if (checking_boot) {
        log("NVIDIA bind: passive devices={d} resources=0 boot-snapshots=checked firmware-execution=disabled fallback=preserved", .{count});
    } else log("NVIDIA bind: passive devices={d} resources=0 native-writes=disabled fallback=preserved", .{count});
    return 0;
}

pub export fn nvidia_shutdown() callconv(.c) i32 {
    const api = driver_api orelse return 0;
    const ctx = r4os.r4dev.DriverContext.init(api);
    if (!wait_probe.shutdown(&ctx)) return -1;
    if (!native_probe.shutdown(&ctx)) return -1;
    if (!rm_semaphore_probe.shutdown(&ctx)) return -1;
    if (!semaphore_probe.shutdown(&ctx)) return -1;
    if (!thread_probe.shutdown(&ctx)) return -1;
    if (!runtime_probe.shutdown(&ctx)) return -1;
    if (closeBootPreparation()) |phase| {
        logBootCleanup(phase);
        return -1;
    }
    if (!gsp_image.close()) return -1;
    if (!firmware_cpu.close()) return -1;
    if (!fwsec_hardware.close()) return -1;
    if (!fwsec_cpu.close()) return -1;
    if (!board_rom.close()) return -1;
    if (!releaseWindow(&ctx)) return -1;
    if (checking_runtime) {
        ctx.logInfo("NVIDIA unbind: driver-state=closed cpu-owner-cleanup=pending native-writes=disabled fallback=preserved");
    } else if (checking_boot) {
        ctx.logInfo("NVIDIA unbind: OK resources=0 firmware-execution=disabled fallback=preserved");
    } else ctx.logInfo("NVIDIA unbind: OK resources=0 native-writes=disabled fallback=preserved");
    rm_wait.unbind();
    rm_log.unbind();
    rm_native.unbind();
    rm_semaphore.unbind();
    rm_heap.unbind();
    rm_clock.unbind();
    checking_runtime = false;
    checking_boot = false;
    starting_gsp = false;
    boot_checked = false;
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
        if (family == .ga10x) {
            const report = gsp_image.stage(ctx, verified.layout.image.slice(verified.container), 30 * std.time.ns_per_s) catch |err| {
                log("NVIDIA gsp: staging=rejected reason={s} submitted=no fallback=preserved", .{@errorName(err)});
                _ = gsp_image.close();
                return false;
            };
            log("NVIDIA gsp: radix3=staged image-bytes={d} allocation-bytes={d} table-bytes={d} mappings={d} segments={d} bounced={d} root={x} synchronized=yes submitted=no", .{
                report.image_bytes, report.allocation_bytes, report.table_bytes, report.mappings, report.segments, report.bounced, report.root_address,
            });
            for (gsp_image.pieces[0..gsp_image.piece_count], 0..) |*piece, index| {
                log("NVIDIA gsp: mapping={d} offset={d} bytes={d} segments={d} bounced={}", .{
                    index, piece.offset, piece.mapping.mapped_bytes, piece.mapping.segment_count, piece.mapping.flags & a.dma_mapping_flag_bounced != 0,
                });
            }
            if (!gsp_image.close()) {
                ctx.logError("NVIDIA gsp: stage-cleanup=retained submitted=no");
                return false;
            }
            ctx.logInfo("NVIDIA gsp: stage-cleanup=OK mappings=0 pins=0 cpu=0 submitted=no");
        }
        if (!firmware_cpu.close()) {
            ctx.logError("NVIDIA firmware: cleanup=retained native-writes=disabled");
            return false;
        }
    }
    ctx.logInfo("NVIDIA firmware-check: OK containers=2 cpu-buffers=closed native-writes=disabled fallback=preserved");
    return true;
}

fn readIdentity(ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, measured: *?identity.Chip) bool {
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
            measured.* = chip;
            log("NVIDIA chip={s} id={x} revision={x} boot0={x:0>8} boot1={x:0>8} profile={s} native-writes=disabled", .{ chip.name, chip.id, chip.revision, boot0, boot1, chip.profile });
            ctx.logInfo("NVIDIA display-generation=GA102-NVDisplay root-class=c670 core-class=c67d source=measured-chip-and-pinned-reference class-query=unperformed native-writes=disabled");
        } else log("NVIDIA chip=unrecognized boot0={x:0>8} boot1={x:0>8} native-writes=disabled", .{ boot0, boot1 });
    } else ctx.logInfo("NVIDIA chip=unmeasured reason=unstable-identity native-writes=disabled");
    return releaseWindow(ctx);
}

fn readVbios(ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip) bool {
    const bytes = board_rom.read(ctx, snapshot, chip) catch |err| {
        log("NVIDIA vbios: rejected phase=read reason={s} source=PROM native-writes=disabled fallback=preserved", .{@errorName(err)});
        _ = board_rom.close();
        return false;
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    log("NVIDIA vbios: snapshot=PROM bytes={d} sha256={s} reads=two-identical aperture=300000..3fffff native-writes=disabled", .{ bytes.len, hex });
    const start = vbios.promStart(bytes) catch |err| {
        log("NVIDIA vbios: rejected phase=IFR reason={s} first={x:0>2}{x:0>2}{x:0>2}{x:0>2} fallback=preserved", .{ @errorName(err), bytes[0], bytes[1], bytes[2], bytes[3] });
        _ = board_rom.close();
        return false;
    };
    const result = vbios.parse(bytes[start.offset..], snapshot.pci.device_id) catch |err| {
        log("NVIDIA vbios: rejected phase=tables reason={s} offset={x} ifr={d} fallback=preserved", .{ @errorName(err), start.offset, start.ifr_version });
        var diagnostic: VbiosDiagnostic = .{};
        @import("vbios_diagnostic.zig").inspect(bytes[start.offset..], &diagnostic);
        _ = board_rom.close();
        return false;
    };
    std.crypto.hash.sha2.Sha256.hash(bytes[start.offset..][0..result.rom_bytes], &digest, .{});
    const rom_hex = std.fmt.bytesToHex(digest, .lower);
    log("NVIDIA vbios: verified source=PROM offset={x} ifr={d} bytes={d} images={d} sha256={s} hardware-bound=yes gpu-authentication=unverified", .{ start.offset, start.ifr_version, result.rom_bytes, result.image_count, rom_hex });
    log("NVIDIA vbios: version={x:0>2}.{x:0>2}.{x:0>2}.{x:0>2}.{x:0>2} version-present={} BIT={x} DCB={x} dcb-version={x} ccb-version={x} ports={d} checksum-bytes={d}", .{
        result.vbios_version[0], result.vbios_version[1], result.vbios_version[2], result.vbios_version[3], result.vbios_version[4], result.version_present,
        result.bit_offset,       result.dcb_offset,       result.dcb_version,      result.ccb_version,      result.port_count,       result.checksum_bytes,
    });
    for (result.ports[0..result.port_count]) |port| {
        log("NVIDIA vbios port={d} type={x} heads={x} output={x} location={d} bus={d} ccb={d} connector={d} connector-type={d} i2c={d} aux={d} raw={x:0>8}/{x:0>8}", .{
            port.index,                                                          port.kind,                                                port.heads,                                               port.output_mask,  port.location,   port.bus, port.ccb, port.connector,
            if (port.connector_type) |value| @as(u16, value) else @as(u16, 256), if (port.i2c) |value| @as(u16, value) else @as(u16, 256), if (port.aux) |value| @as(u16, value) else @as(u16, 256), port.raw_path, port.raw_config,
        });
        log("NVIDIA vbios assignment: port={d} kind={s} mask={x} links={?} virtual={} state=wiring-only", .{
            port.index, @tagName(port.assignment), port.output_mask, port.link_mask, port.virtual,
        });
    }
    log("NVIDIA topology: source=VBIOS connectors={d} ccb={d} live-HPD=unknown active-route=unknown receiver=unread", .{ result.connector_count, result.communication_count });
    for (result.communications[0..result.communication_count]) |*comms| {
        log("NVIDIA ccb={d} bytes={d} raw={x:0>8} speed-code={x} max-hz={d} reserved={x} paths={x} connectors={x}", .{
            comms.index, comms.entry_bytes, comms.raw, comms.speed_code, comms.max_i2c_hz orelse 0, comms.reserved_bits, comms.display_paths, comms.connector_mask,
        });
    }
    for (result.connectors[0..result.connector_count]) |*connector| {
        log("NVIDIA connector={d} bytes={d} type={x} location={d} raw={x:0>8} HPD-mask={x} DP-DVI-mask={x} mux-mask={d} paths={x} heads={x} encoders={x} pads={x} buses={x} ccb={x}", .{
            connector.index, connector.entry_bytes, connector.kind, connector.location, connector.raw, connector.hpd_mask, connector.dp_dvi_mask,
            if (connector.mux_mask) |value| @as(u16, value) else @as(u16, 256), connector.display_paths, connector.heads, connector.encoder_mask, connector.pad_mask, connector.logical_bus_mask, connector.ccb_mask,
        });
    }
    if (result.gpio_table) |*gpio| {
        log("NVIDIA gpio-table: version={x} offset={x} bytes={d} entries={d} stride={d} external-offset={x} state=metadata-only", .{
            gpio.version, gpio.offset, gpio.byte_length, gpio.count, gpio.entry_bytes, gpio.external_table_offset orelse 0,
        });
        for (&gpio.hpd, 0..) |*hpd, i| {
            log("NVIDIA HPD-function: mask={x} function={d} status={s} matches={d} entry={d} pin={d} active-high={d} level=unread", .{
                @as(u8, 1) << @as(u3, @intCast(i)), hpd.function, @tagName(hpd.status), hpd.matches,
                if (hpd.entry_index) |value| @as(u16, value) else @as(u16, 256),
                if (hpd.line) |value| @as(u16, value) else @as(u16, 256),
                if (hpd.active_high) |value| @as(u8, @intFromBool(value)) else @as(u8, 2),
            });
        }
    } else ctx.logInfo("NVIDIA gpio-table: absent live-HPD=unknown");
    if (result.external_gpio) |*external| {
        log("NVIDIA xpio: master={x} slots={d} tables={d} entries={d} primary-ccb={?} secondary-ccb={?} state=metadata-only", .{
            external.master.offset, external.master_count, external.table_count, external.entry_count, result.primary_ccb, result.secondary_ccb,
        });
        for (external.tables[0..external.table_count]) |*item| {
            log("NVIDIA xpio-table: slot={d} type={x} address={x} flags={x} entries={d} ccb={?} pmgr-i2c={?} pmgr-aux={?} metadata-known={} pin-levels=unread", .{
                item.index, item.kind, item.address, item.flags, item.count, item.ccb, item.i2c, item.aux, item.knownWiring(),
            });
            if (item.interrupt) |signal| log("NVIDIA xpio-interrupt: slot={d} function={d} status={s} pin={?} active-high={?} level=unread", .{
                item.index, signal.function, @tagName(signal.status), signal.line, signal.active_high,
            });
        }
    }
    if (!inspectFwsec(ctx, snapshot, chip, bytes[start.offset..][0..result.rom_bytes], &result)) return false;
    if (!board_rom.close()) return false;
    ctx.logInfo("NVIDIA vbios: cleanup=OK resources=0 PROM-writes=disabled fallback=preserved");
    return true;
}

fn inspectFwsec(ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip, rom: []const u8, board: *const vbios.Result) bool {
    log("NVIDIA fwsec: source=PROM expansion-bias={x} first-extension={x} bit-p={} native-writes=disabled", .{
        board.expansion_rom_offset orelse 0xffffffff, board.first_extension_offset orelse 0xffffffff, board.falcon != null,
    });
    const catalog = fwsec.parse(rom, board) catch |err| {
        log("NVIDIA fwsec: unavailable reason={s} firmware-ready=no fallback=preserved", .{@errorName(err)});
        var diagnostic: VbiosDiagnostic = .{ .remaining = 2048 };
        fwsec.diagnose(rom, board, &diagnostic);
        return true;
    };
    log("NVIDIA fwsec: catalog=parsed table={x} table-bytes={d} table-entries={d} fwsec-entries={d} gpu-authentication=unverified", .{
        catalog.table.offset, catalog.table.bytes, catalog.table_entries, catalog.count,
    });
    for (catalog.entries[0..catalog.count]) |*entry| {
        log("NVIDIA fwsec: entry={d} app={x} target={x} desc-version={d} flags={x} descriptor={x}/{d} image={x}/{d} stored={d} uncompressed={d}", .{
            entry.table_index,        entry.application,      entry.target,       entry.descriptor_version, entry.flags,
            entry.descriptor.offset,  entry.descriptor.bytes, entry.image.offset, entry.image.bytes,        entry.stored_bytes,
            entry.uncompressed_bytes,
        });
        log("NVIDIA fwsec: code={x}/{d} data={x}/{d} imem-pa={x} imem-va={x} secure-pa={x} secure-bytes={d} dmem-pa={x} engine-mask={x} ucode={x}", .{
            entry.code.offset,    entry.code.bytes,        entry.data.offset, entry.data.bytes,  entry.imem_pa,  entry.imem_va,
            entry.imem_secure_pa, entry.imem_secure_bytes, entry.dmem_pa,     entry.engine_mask, entry.ucode_id,
        });
        log("NVIDIA fwsec: signatures={x}/{d} count={d} versions={x} reserved-raw={x} patch-slot={x}/{d} selected=no", .{
            entry.signatures.offset, entry.signatures.bytes,      entry.signature_count,      entry.signature_versions,
            entry.reserved_raw,      entry.signature_slot.offset, entry.signature_slot.bytes,
        });
        const interface = &entry.interface;
        log("NVIDIA fwsec: interface={x}/{d} mapper={x}/{d} mapper-version={d} signature={x} input={x}/{d} output-address={x}/{d} output-space=firmware-unresolved command-mask={x}/{x} submitted=no", .{
            interface.table.offset,           interface.table.bytes,          interface.mapper.offset,        interface.mapper.bytes,
            interface.version,                interface.signature,            interface.command_input.offset, interface.command_input.bytes,
            interface.command_output.address, interface.command_output.bytes, interface.commands[0],          interface.commands[1],
        });
        inline for (.{ "descriptor", "image", "signatures" }) |field| {
            const value: fwsec.Range = @field(entry, field);
            if (value.bytes != 0) {
                const digest = fwsec.sha256(rom, value) catch unreachable; // Immutable, fully bounded catalog.
                log("NVIDIA fwsec: entry={d} {s}-sha256={s}", .{ entry.table_index, field, digest });
            }
        }
    }
    const fuses = security_fuses.read(ctx, snapshot, chip, &catalog) catch |err| {
        log("NVIDIA fwsec: preparation=unavailable phase=fuses reason={s} firmware-ready=no fallback=preserved", .{@errorName(err)});
        return security_fuses.close();
    };
    // A retained MMIO mapping must be closed before a CPU image is published.
    if (!security_fuses.close()) return false;
    log("NVIDIA fwsec: fuses=measured debug-disable={x:0>8} ucode={x} version-raw={x:0>8} version={d} reads=two-identical registers=82074c/{x} mmio-cleanup=OK", .{
        fuses.debug_disable_raw,                                           fuses.ucode_id, fuses.ucode_version_raw, fwsec_prepare.fuseVersion(fuses.ucode_version_raw) catch unreachable,
        fwsec_probe.version_register + 4 * (@as(u32, fuses.ucode_id) - 1),
    });
    const prepared = fwsec_cpu.prepare(ctx, rom, board, fuses) catch |err| {
        log("NVIDIA fwsec: preparation=unavailable phase=cpu-image reason={s} firmware-ready=no fallback=preserved", .{@errorName(err)});
        return fwsec_cpu.close();
    };
    const chosen = &prepared.metadata.selection;
    log("NVIDIA fwsec: selected-entry={d} app={x} variant={s} fuse-version={d} signature={x}/{d} signature-sha256={s}", .{
        chosen.entry.table_index, chosen.entry.application, if (chosen.debug) @as([]const u8, "debug") else "production", chosen.fuse_version,
        chosen.signature.offset,  chosen.signature.bytes,   fwsec.sha256(rom, chosen.signature) catch unreachable,
    });
    log("NVIDIA fwsec: cpu-image=prepared bytes={d} command={x} input-bytes=24 image-sha256={s} gpu-address=none gpu-authentication=unverified submitted=no", .{
        prepared.metadata.bytes, prepared.metadata.command, fwsec.sha256(prepared.image, .{ .bytes = prepared.metadata.bytes }) catch unreachable,
    });
    const load_plan = fwsec_cpu.device.stage(ctx, prepared.image, &prepared.metadata) catch |err| {
        log("NVIDIA fwsec: preparation=unavailable phase=dma-image reason={s} firmware-ready=no fallback=preserved", .{@errorName(err)});
        return fwsec_cpu.close();
    };
    log("NVIDIA fwsec: dma-image=staged bytes={d} segments=1 address={x} bounced={} direction=to-device synchronized=yes submitted=no", .{
        prepared.metadata.bytes, fwsec_cpu.device.mapping.segments[0].phys_addr, (fwsec_cpu.device.mapping.flags & a.dma_mapping_flag_bounced) != 0,
    });
    log("NVIDIA fwsec: load-plan=validated imem-base={x} imem-destination={x} imem-offset={x} imem-blocks={d} imem-command={x}", .{
        load_plan.imem.base, load_plan.imem.destination, load_plan.imem.source_offset, load_plan.imem.bytes / 256, load_plan.imem.command,
    });
    log("NVIDIA fwsec: dmem-base={x} dmem-destination={x} dmem-offset={x} dmem-blocks={d} dmem-command={x} pkc-address={x} boot-vector={x} execution=not-started", .{
        load_plan.dmem.base, load_plan.dmem.destination, load_plan.dmem.source_offset, load_plan.dmem.bytes / 256, load_plan.dmem.command, load_plan.signature_address, load_plan.boot_vector,
    });
    if (!inspectFwsecState(ctx, snapshot, chip, &load_plan, .{ .rom = rom, .board = board, .fuses = fuses })) return false;
    if (starting_gsp and boot_checked) return true; // Native run retains its SB image.
    if (!fwsec_cpu.close()) return false;
    log("NVIDIA fwsec: preparation-cleanup=OK resources=0", .{});
    log("NVIDIA fwsec: firmware-ready=no native-writes=disabled fallback=preserved", .{});
    return true;
}

const FwsecSource = struct { rom: []const u8, board: *const vbios.Result, fuses: fwsec_prepare.Fuses };
fn inspectFwsecState(ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip, plan: *const @import("fwsec_load.zig").Plan, source: FwsecSource) bool {
    const raw = fwsec_hardware.read(ctx, snapshot, chip) catch |err| {
        log("NVIDIA fwsec: preflight=unavailable phase=registers reason={s} native-writes=disabled", .{@errorName(err)});
        return fwsec_hardware.close();
    };
    if (!fwsec_hardware.close()) return false;
    for (fwsec_state.addresses, 0..) |address, index| {
        const reg: fwsec_state.Register = @enumFromInt(index);
        if (raw.has(reg)) log("NVIDIA fwsec preflight: register={s} address={x} value={x:0>8} reads=two-identical", .{ @tagName(reg), address, raw.values[index] });
    }
    const observed = fwsec_state.decode(&raw) catch |err| {
        log("NVIDIA fwsec: preflight=unavailable phase=decode reason={s} mmio-cleanup=OK native-writes=disabled", .{@errorName(err)});
        return true;
    };
    log("NVIDIA fwsec: preflight=observed imem-bytes={d} dmem-bytes={d} reset={} reset-ready-hint={} scrubbing={} falcon-halted={} dma-idle={} dma-full={}", .{
        observed.imem_bytes, observed.dmem_bytes, observed.reset_asserted, observed.reset_ready_hint, observed.scrubbing, observed.falcon_halted, observed.dma_idle, observed.dma_full,
    });
    log("NVIDIA fwsec: riscv-enabled={} riscv-selected={} riscv-active={} riscv-halted={} bcr-valid={} ownership=unclaimed", .{
        observed.riscv_enabled, observed.riscv_selected, observed.riscv_active, observed.riscv_halted, observed.bcr_valid,
    });
    log("NVIDIA fwsec: fb-bytes={d} wpr2-up={} wpr2-lo={x} wpr2-hi={x} mmu-lock=not-applicable-ga106", .{ observed.fb_bytes, observed.wpr_up, observed.wpr_lo, observed.wpr_hi });
    log("NVIDIA fwsec: display-enabled={} vga-valid={} vga-base={x} relocation-needed={} reserved-base={x} frts-allocation=none", .{
        observed.display_enabled, observed.vga_valid, observed.vga_base, observed.vga_relocation_needed, observed.reserved_base,
    });
    observed.checkTcm(plan) catch |err| {
        log("NVIDIA fwsec: preflight=unavailable phase=tcm reason={s} mmio-cleanup=OK native-writes=disabled", .{@errorName(err)});
        return true;
    };
    ctx.logInfo("NVIDIA fwsec: preflight-tcm=fits snapshot=read-only mmio-cleanup=OK reset=unperformed execution=not-started");
    if (checking_boot and !checkBoot(ctx, snapshot, chip, raw, source)) {
        // The kernel cannot begin unloading a driver that still holds the
        // display. Recover our unsubmitted preparation while init owns it;
        // waiting for DriverShutdown here would leave bootfb revoked forever.
        logBootCleanup(closeBootPreparation());
        return false;
    }
    return true;
}

fn logBootScanout(raw: *const @import("boot_scanout.zig").Raw) void {
    const scanout = @import("boot_scanout.zig");
    const routed = scanout.routedHeads(raw);
    log("NVIDIA boot-scanout: heads={x:0>2} sors={x:0>2} routed-heads={x:0>2} core-client={x} source=armed-mirror repeated=matched visible=unverified", .{ raw.headMask(), raw.sorMask(), routed, raw.core_client });
    log("NVIDIA boot-instance: control={x:0>8} address={x:0>8} registers=610010/610014 source=two-identical-reads validity=unclassified", .{ raw.instance_control, raw.instance_address });
    log("NVIDIA boot-windows: count={d} mask={x:0>8} source=armed-mirror layout=unresolved", .{ raw.windowCount(), raw.window_mask });
    for (0..scanout.max_windows) |index| if (raw.window_mask & (@as(u32, 1) << @intCast(index)) != 0) {
        const display_window = &raw.windows[index];
        const owner = scanout.windowHead(display_window) catch continue;
        if (owner) |head| {
            const size = display_window.dimensions(.size);
            const input = display_window.dimensions(.input);
            const output = display_window.dimensions(.output);
            log("NVIDIA boot-window: id={d} head={d} surface={d}x{d} input={d}x{d} output={d}x{d} format={x:0>2} storage={x:0>8} pitch-raw={x:0>8}/{x:0>8}/{x:0>8}", .{
                index, head, size.x, size.y, input.x, input.y, output.x, output.y,
                display_window.get(.params) & 0xff, display_window.get(.storage), display_window.get(.pitch0), display_window.get(.pitch1), display_window.get(.pitch2),
            });
            for (0..3) |plane| for (0..2) |eye| {
                const binding = display_window.binding(@intCast(plane), @intCast(eye)) catch continue;
                if (binding.handle != 0) log("NVIDIA boot-plane: window={d} plane={d} eye={d} context={x:0>8} offset-bytes={x} address=unresolved", .{
                    index, plane, eye, binding.handle, binding.offset_bytes,
                });
            };
        } else log("NVIDIA boot-window: id={d} head=none raw-state=retained", .{index});
    };
    for (0..scanout.max_windows) |index| if (raw.window_mask & (@as(u32, 1) << @intCast(index)) != 0) {
        const fields = &raw.windows[index].color;
        log("NVIDIA boot-color-window: id={d} ilut-handle={x} ilut-control={x} tmo-handle={x} tmo-control={x} indexed-luts={x} indexed-data=unresolved", .{
            index, fields.get(.ilut_dma), fields.get(.ilut_control), fields.get(.tmo_dma), fields.get(.tmo_control), fields.indexedLuts(),
        });
    };
    for (0..scanout.max_heads) |index| if (raw.headMask() & (@as(u8, 1) << @intCast(index)) != 0) {
        const fields = &raw.heads[index].color;
        const left = fields.cursorPoint(0);
        const right = fields.cursorPoint(1);
        log("NVIDIA boot-cursor: head={d} enabled={} control={x} present={x} left={d},{d} right={d},{d} handles={x},{x} offsets={x},{x}", .{
            index, fields.cursorEnabled(), fields.get(.cursor_control), fields.get(.cursor_present), left.x, left.y, right.x, right.y,
            fields.get(.cursor_dma_left), fields.get(.cursor_dma_right), fields.get(.cursor_offset_left), fields.get(.cursor_offset_right),
        });
        log("NVIDIA boot-color-head: id={d} olut-handle={x} olut-control={x} olut-norm={x} csc-control={x},{x} payloads=pending-context-capture", .{
            index, fields.get(.olut_dma), fields.get(.olut_control), fields.get(.olut_norm), fields.get(.csc0_control), fields.get(.csc1_control),
        });
    };
    for (0..scanout.max_sors) |sor| if (raw.sorMask() & (@as(u8, 1) << @intCast(sor)) != 0) {
        log("NVIDIA boot-sor: id={d} heads={x:0>2} protocol={s} control={x:0>8}", .{ sor, raw.sors[sor] & 0xff, @tagName(scanout.protocol(raw.sors[sor])), raw.sors[sor] });
    };
    for (0..scanout.max_heads) |head| if (routed & (@as(u8, 1) << @intCast(head)) != 0) {
        const timing = scanout.timing(&raw.heads[head]) catch |err| {
            log("NVIDIA boot-head: id={d} timing=unknown reason={s} raw-state=retained", .{ head, @errorName(err) });
            continue;
        };
        log("NVIDIA boot-head: id={d} active={d}x{d} total={d}x{d} viewport-in={d}x{d} viewport-out={d}x{d} pixel-hz={d}/{d} raster-microhz={d} depth-code={d} hdmi={}", .{
            head, timing.active.x, timing.active.y, timing.total.x, timing.total.y,
            timing.viewport_in.x, timing.viewport_in.y, timing.viewport_out.x, timing.viewport_out.y,
            timing.pixel_clock_numerator, timing.pixel_clock_denominator, timing.raster_micro_hz, timing.depth_code, timing.hdmi_enabled,
        });
    };
}

fn checkBoot(ctx: *const r4os.r4dev.DriverContext, snapshot: *const identity.Snapshot, chip: identity.Chip, raw: fwsec_state.Raw, source: FwsecSource) bool {
    const vram_copy = boot_vram.capture(ctx, snapshot, chip) catch |err| {
        log("NVIDIA boot-vram: rejected reason={s} status={d} window-writes={d} firmware-execution=disabled", .{
            @errorName(err), boot_vram.last_status, boot_vram.window_writes,
        });
        if (!boot_vram.close()) ctx.logError("NVIDIA boot-vram: cleanup=retained display-and-snapshot=held");
        return false;
    };
    const display_copy = vram_copy.boot;
    logBootScanout(&boot_vram.scanout_original.?);
    const snapshot_hash = std.fmt.bytesToHex(display_copy.sha256, .lower);
    log("NVIDIA boot-display: captured bytes={d} geometry={d}x{d} pitch={d} boot-generation={d} hold-generation={d} sha256={s} writers=revoked snapshot=immutable capture-phase=before-window", .{
        display_copy.bytes, display_copy.boot.width, display_copy.boot.height, display_copy.boot.pitch,
        display_copy.boot.generation, display_copy.hold_generation, snapshot_hash,
    });
    const vram_hash = std.fmt.bytesToHex(vram_copy.sha256, .lower);
    log("NVIDIA boot-vram: captured address={x} bytes={d} sha256={s} window-original={x:0>8} window-restored={} window-writes={d} firmware-execution=disabled", .{
        vram_copy.range.address, vram_copy.range.bytes, vram_hash, vram_copy.window_original, vram_copy.window_restored, vram_copy.window_writes,
    });
    const mapping_copy = boot_mapping.capture(&boot_vram) catch |err| {
        log("NVIDIA boot-mapping: rejected reason={s} status={d} firmware-execution=disabled", .{ @errorName(err), boot_mapping.last_status });
        if (!boot_mapping.close()) ctx.logError("NVIDIA boot-mapping: cleanup=retained display-and-registers=held");
        return false;
    };
    const mapping_hash = std.fmt.bytesToHex(mapping_copy.sha256, .lower);
    log("NVIDIA boot-mapping: bytes={d} ranges={d} table-pages={d} format={s} tables-sha256={s} window-writes={d} restored=yes firmware-execution=disabled", .{
        mapping_copy.bytes, mapping_copy.ranges, mapping_copy.pages, @tagName(mapping_copy.format), mapping_hash, mapping_copy.window_writes,
    });
    const context_copy = boot_context.capture(&boot_vram) catch |err| {
        log("NVIDIA boot-context: rejected reason={s} status={d} firmware-execution=disabled", .{ @errorName(err), boot_context.last_status });
        if (!boot_context.close()) ctx.logError("NVIDIA boot-context: cleanup=retained");
        return false;
    };
    const context_hash = std.fmt.bytesToHex(context_copy.sha256, .lower);
    log("NVIDIA boot-context: instance-active={} address={x} bytes={d} used-planes={d} sha256={s} window-writes={d} restored=yes immutable=yes", .{
        context_copy.instance_active, context_copy.address, context_copy.bytes, context_copy.surfaces, context_hash, context_copy.window_writes,
    });
    for (boot_context.surfaces[0..boot_context.surface_count]) |*surface| {
        log("NVIDIA boot-surface: window={d} plane={d} eye={d} handle={x} instance-offset={x} vram={x} bytes={d} row-bytes={d} rows={d} layout={s} backup-offset={d}", .{
            surface.window, surface.plane, surface.eye, surface.handle, surface.context.offset,
            surface.image.span.address, surface.image.span.bytes, surface.image.row_bytes, surface.image.rows, @tagName(surface.image.layout), surface.backup_offset,
        });
    }
    const payload_hash = std.fmt.bytesToHex(context_copy.payload_sha256, .lower);
    log("NVIDIA boot-payload: image-bindings={d} asset-bindings={d} unique-ranges={d} bytes={d} sha256={s} immutable=yes native-restore=incomplete", .{
        context_copy.surfaces, context_copy.assets, context_copy.payload_ranges, context_copy.payload_bytes, payload_hash,
    });
    const asset_hash = std.fmt.bytesToHex(context_copy.asset_sha256, .lower);
    log("NVIDIA boot-assets: count={d} bytes={d} sha256={s} immutable=yes target=vram indexed-tables=unresolved recovery=incomplete", .{
        context_copy.assets, context_copy.asset_bytes, asset_hash,
    });
    for (boot_context.asset_catalog.items[0..boot_context.asset_catalog.count]) |*asset| {
        log("NVIDIA boot-asset: kind={s} owner={d} eye={d} handle={x} context={x} target={s} address={x} bytes={d} backup-offset={d}", .{
            @tagName(asset.kind), asset.owner, asset.eye, asset.handle, asset.binding.offset, @tagName(asset.memory.target),
            asset.memory.span.address, asset.memory.span.bytes, asset.backup_offset,
        });
    }
    const inputs = boot_inputs.load(ctx, 30 * std.time.ns_per_s) catch |err| {
        log("NVIDIA boot-check: rejected phase=boot-resources reason={s} fallback=preserved", .{@errorName(err)});
        boot_inputs.close();
        return false;
    };
    log("NVIDIA boot-resource: verified image-bytes={d} descriptor-bytes={d} license=matched generation={d} reads={d} source=loaded-r4d gpu-authentication=unverified", .{
        inputs.image.len, inputs.descriptor.len, boot_inputs.generation, boot_inputs.reads,
    });
    firmware_cpu.begin(ctx, .ga10x, 30 * std.time.ns_per_s) catch |err| {
        log("NVIDIA boot-check: rejected phase=gsp-resource reason={s} fallback=preserved", .{@errorName(err)});
        boot_inputs.close();
        _ = firmware_cpu.close();
        return false;
    };
    while (firmware_cpu.ready() == null) {
        _ = firmware_cpu.step() catch |err| {
            log("NVIDIA boot-check: rejected phase=gsp-admission reason={s} fallback=preserved", .{@errorName(err)});
            boot_inputs.close();
            _ = firmware_cpu.close();
            return false;
        };
    }
    const verified = firmware_cpu.ready().?;
    const report = boot_storage.stageAdmitted(ctx, &.{
        .chip_id = chip.id,
        .raw = raw,
        .image = verified.layout.image.slice(verified.container),
        .boot_image = inputs.image,
        .descriptor = inputs.descriptor,
        .signature = verified.layout.signature.slice(verified.container),
    }, 30 * std.time.ns_per_s) catch |err| {
        log("NVIDIA boot-check: rejected phase=dma-pack reason={s} submitted=no fallback=preserved", .{@errorName(err)});
        _ = boot_storage.close();
        boot_inputs.close();
        _ = firmware_cpu.close();
        return false;
    };
    log("NVIDIA boot-check: staged image-bytes={d} image-mappings={d} image-segments={d} radix-root={x} pack-bytes={d} pack-bounced={} synchronized=yes submitted=no", .{
        report.image.image_bytes, report.image.mappings, report.image.segments, report.image.root_address, report.pack_bytes, report.pack_bounced,
    });
    boot_vram_lease.acquire(&boot_vram, &boot_storage, &boot_mapping, &boot_context) catch |err| {
        log("NVIDIA boot-vram: reservation=rejected reason={s} submitted=no", .{@errorName(err)});
        return false;
    };
    const frts = boot_vram_lease.binding(.frts) catch return false;
    log("NVIDIA boot-vram: reservation=held epoch={d} serial={d} fb-bytes={d} frts-address={x} frts-bytes={d} metadata=matched general-allocation=withheld submitted=no", .{
        frts.epoch, frts.serial, boot_vram_lease.plan.?.fb_bytes, frts.range.offset, frts.range.bytes,
    });
    log("NVIDIA boot-check: boot-address={x} signature-address={x} metadata-address={x} metadata-bytes={d} verified=0 boot-count=0 vram-reserved=boot-owner vga-relocated=no", .{
        report.boot_address, report.signature_address, report.metadata_address, report.metadata_bytes,
    });
    // Keep the original immutable SB image for normal teardown. FRTS uses
    // separate CPU/DMA storage; no later recovery path must reallocate SB.
    if (!fwsec_cpu.preparationValid() or fwsec_cpu.command != 0x19) return false;
    const sb_plan = fwsec_cpu.device.prepared_plan orelse return false;
    const security = fwsec_frts.prepareFrts(ctx, source.rom, source.board, source.fuses, &boot_vram_lease) catch |err| {
        log("NVIDIA boot-frts: rejected phase=cpu-preparation reason={s} submitted=no", .{@errorName(err)});
        return false;
    };
    const security_plan = fwsec_frts.device.stage(ctx, security.image, &security.metadata) catch |err| {
        log("NVIDIA boot-frts: rejected phase=dma-preparation reason={s} submitted=no", .{@errorName(err)});
        return false;
    };
    const current = fwsec_state.decode(&boot_vram.observation.?) catch return false;
    current.checkTcm(&security_plan) catch return false;
    current.checkTcm(&sb_plan) catch return false;
    if (!fwsec_frts.preparationValid()) return false;
    log("NVIDIA boot-frts: staged command={x} input-bytes=48 target-address={x} target-bytes={d} epoch={d} serial={d} dma-address={x} synchronized=yes submitted=no", .{
        security.metadata.command, frts.range.offset, frts.range.bytes, frts.epoch, frts.serial, fwsec_frts.device.mapping.segments[0].phys_addr,
    });
    log("NVIDIA boot-sb: retained command=19 bytes={d} dma-address={x} purpose=normal-teardown synchronized=yes submitted=no", .{
        fwsec_cpu.allocation.byte_length, fwsec_cpu.device.mapping.segments[0].phys_addr,
    });
    const fuses = security_fuses.readBooterShared(ctx, snapshot, chip, &boot_vram.registers) catch |err| {
        log("NVIDIA booters: rejected phase=fuses reason={s} submitted=no", .{@errorName(err)});
        _ = security_fuses.close();
        return false;
    };
    if (!security_fuses.close()) return false;
    log("NVIDIA booters: fuses=measured debug-disable={x:0>8} ucode={d} version-raw={x:0>8} version={d} registers=82074c/8241c8 reads=two-identical mmio-cleanup=OK", .{
        fuses.debug_disable_raw, fuses.ucode_id, fuses.ucode_version_raw, fwsec_prepare.fuseVersion(fuses.ucode_version_raw) catch return false,
    });
    booters.stage(ctx, chip.id, fuses, boot_inputs.generation, 30 * std.time.ns_per_s) catch |err| {
        log("NVIDIA booters: rejected phase=resources-and-dma reason={s} submitted=no", .{@errorName(err)});
        return false;
    };
    for (&booters.images) |*image| {
        const prepared = image.prepared.?;
        const plan = image.device.prepared_plan.?;
        log("NVIDIA booters: operation={s} bytes={d} signature-index={d} fuse-version={d} dma-address={x} bounced={} imem-bytes={d} dmem-bytes={d} pkc-address={x} synchronized=yes submitted=no", .{
            @tagName(prepared.operation),                                   prepared.info.image_bytes, prepared.signature_index, prepared.fuse_version,  image.device.mapping.segments[0].phys_addr,
            (image.device.mapping.flags & a.dma_mapping_flag_bounced) != 0, plan.imem.bytes,           plan.dmem.bytes,          plan.signature_address,
        });
    }
    log("NVIDIA booters: resources=14 license=matched generation={d} reads={d} source=loaded-r4d gpu-authentication=unverified", .{ booters.generation, booters.reads });
    if (!stageBootInit(ctx, chip.id)) return false;
    if (starting_gsp) {
        native_device.open(ctx, &boot_vram, &boot_vram_lease, &run_memory, &firmware_logs, source.board) catch |err| {
            log("NVIDIA gsp-start: rejected phase=owner reason={s} firmware-execution=disabled", .{@errorName(err)});
            return false;
        };
        if (starting_native) native_device.native_output.request(ctx, &native_device.running, &boot_vram) catch |err| {
            log("NVIDIA native-output: rejected phase=owner reason={s} firmware-execution=disabled", .{@errorName(err)});
            return false;
        };
        if (starting_native) native_device.native_output.frame_count = native_frame_count;
        if (starting_native) if (native_hda) |sibling| native_device.native_output.audio.attach(&native_device.catalog, sibling);
        native_work.start(ctx, &native_device) catch |err| {
            log("NVIDIA gsp-start: rejected phase=worker reason={s} firmware-execution=disabled", .{@errorName(err)});
            return false;
        };
        boot_checked = true;
        return true;
    }
    if (closeBootPreparation()) |phase| {
        logBootCleanup(phase);
        return false;
    }
    if (!firmware_cpu.close()) return false;
    ctx.logInfo("NVIDIA boot-init: cleanup=OK mappings=0 pins=0 cpu=0 submitted=no");
    ctx.logInfo("NVIDIA boot-display: cleanup=OK writers=restored snapshot-references=0 aperture-recovery=verified firmware-recovery=unperformed");
    boot_checked = true;
    ctx.logInfo("NVIDIA boot-check: OK mappings=0 pins=0 cpu=0 firmware-execution=disabled fallback=preserved");
    return true;
}

fn stageBootInit(ctx: *const r4os.r4dev.DriverContext, chip_id: u16) bool {
    const image_spans = boot_storage.image.segments[0..boot_storage.image.segment_count];
    @memcpy(init_excluded[0..image_spans.len], image_spans);
    const pack = boot_storage.mapping.segments[0];
    const security = fwsec_frts.device.mapping.segments[0];
    const sb = fwsec_cpu.device.mapping.segments[0];
    init_excluded[image_spans.len] = .{ .address = pack.phys_addr, .bytes = pack.bytes };
    init_excluded[image_spans.len + 1] = .{ .address = security.phys_addr, .bytes = security.bytes };
    init_excluded[image_spans.len + 2] = .{ .address = sb.phys_addr, .bytes = sb.bytes };
    for (&booters.images, 0..) |*image, n| {
        const segment = image.device.mapping.segments[0];
        init_excluded[image_spans.len + 3 + n] = .{ .address = segment.phys_addr, .bytes = segment.bytes };
    }
    const count = image_spans.len + 5;
    const report = init_storage.stage(ctx, chip_id, init_excluded[0..count], 30 * std.time.ns_per_s) catch |err| {
        log("NVIDIA boot-init: rejected phase=dma-init reason={s} submitted=no fallback=preserved", .{@errorName(err)});
        return false;
    };
    log("NVIDIA boot-init: staged bytes={d} mappings={d} logs={d} queue-segments={d} bounced={d} excluded-spans={d} synchronized=yes submitted=no", .{
        gsp_init.output_bytes, report.mappings, report.init.log_regions, report.queue_segments, report.bounced, count,
    });
    log("NVIDIA boot-init: libos-address={x} rm-address={x} queue-table={x} queue-pages={d} ring-slots={d} capacity={d} linked=no firmware-ready=no", .{
        report.init.libos_address, report.init.rm_address, report.init.queues_address, report.init.queue_page_count, gsp_init.ring_slots, gsp_init.ring_capacity,
    });
    ctx.logInfo("NVIDIA boot-init: arguments=to-device logs=bidirectional queues=bidirectional status-header=zero native-writes=disabled");
    run_memory.acquire(ctx, &boot_storage, &init_storage, &fwsec_frts, &fwsec_cpu, &booters) catch |err| {
        log("NVIDIA boot-init: rejected phase=run-memory reason={s} status={d} submitted=no", .{ @errorName(err), init_storage.last_queue_status });
        return false;
    };
    firmware_logs.open(&run_memory) catch |err| {
        log("NVIDIA boot-logs: rejected phase=owner reason={s} submitted=no", .{@errorName(err)});
        return false;
    };
    for (0..gsp_init.log_count) |index| {
        const observed = firmware_logs.capture(index, init_storage.deadline, &firmware_log_words) catch |err| {
            log("NVIDIA boot-logs: rejected phase=read index={d} reason={s} status={d} submitted=no", .{ index, @errorName(err), run_memory.last_log_status });
            return false;
        };
        if (observed.next_word != 0 or observed.word_count != 0 or observed.lost_words != 0) {
            log("NVIDIA boot-logs: rejected phase=initial-state index={d} put={d} submitted=no", .{ index, observed.next_word });
            return false;
        }
    }
    log("NVIDIA boot-logs: reader=OK logs={d} capacity-words={d} counters=zero bytes=80 dma=read-only epoch={d} firmware-execution=disabled", .{ gsp_init.log_count, @import("gsp_logs.zig").capacity, firmware_logs.generation() });
    const bindings = run_memory.inputs() catch return false;
    if (bindings.fwsec_command != 0x15 or bindings.frts == null or !boot_vram_lease.validates(bindings.frts.?)) return false;
    const port = run_memory.transportPort() catch return false;
    const before = port.now_ns(port.context);
    if (before == std.math.maxInt(u64) or before >= init_storage.deadline) return false;
    var command: [32]u8 = undefined;
    var status: [32]u8 = undefined;
    port.read(port.context, init_storage.deadline, .command, 0, &command) catch |err| {
        log("NVIDIA boot-init: rejected phase=command-header reason={s} status={d} submitted=no", .{ @errorName(err), run_memory.queue.last_status });
        return false;
    };
    port.read(port.context, init_storage.deadline, .status, 0, &status) catch |err| {
        log("NVIDIA boot-init: rejected phase=status-header reason={s} status={d} submitted=no", .{ @errorName(err), run_memory.queue.last_status });
        return false;
    };
    const after = port.now_ns(port.context);
    if (after < before or after >= init_storage.deadline) return false;
    const header = @import("gsp_ring.zig").inspect(&command) catch return false;
    if (header.write != 0 or header.layout.flags != 1 or header.layout.rx_offset != 32 or
        header.layout.entries_offset != gsp_init.page_bytes or header.layout.slots != gsp_init.ring_slots or
        !std.mem.allEqual(u8, &status, 0)) return false;
    log("NVIDIA boot-init: queue-port=OK epoch={d} command-bytes=32 status-bytes=32 status=zero writes=0 lease=held submitted=no", .{run_memory.generation()});
    log("NVIDIA boot-init: run-memory=held allocations=7 dma-mappings={d} libos-address={x} app-version={x} fwsec=frts+sb firmware-command=unsubmitted", .{
        run_memory.mapped_count, bindings.resume_args.libos_dma, bindings.resume_args.app_version,
    });
    return true;
}

fn closeBootInit() bool {
    if (!native_work.stop()) return false;
    if (!native_device.closeBeforeSubmission()) return false;
    if (!firmware_logs.close()) return false;
    if (!run_memory.releaseBeforeSubmission()) return false;
    if (!init_storage.close()) return false;
    return booters.close();
}

/// Shared by successful boot-check completion and shutdown. The display
/// context/payload copies must close before BAR1 dependencies; either failure
/// leaves the parent boot hold for its caller's later retry.
pub fn closeBootMappings(context: *@import("boot_context.zig").Capture, mapping: *@import("boot_mapping.zig").Capture) bool {
    return context.close() and mapping.close();
}

/// One dependency order for successful preparation, init failure and
/// shutdown. Every release is restricted to the unsubmitted preparation;
/// uncertainty retains the exact owners and prevents kernel resource reuse.
fn closeBootPreparation() ?[]const u8 {
    if (!closeBootInit()) return "init";
    if (!security_fuses.close()) return "fuses";
    if (!fwsec_frts.close()) return "frts";
    if (boot_vram_lease.self_address != 0 and !fwsec_cpu.close()) return "sb";
    if (!boot_vram_lease.releaseBeforeSubmission()) return "vram-reservation";
    if (!boot_storage.close()) return "boot-storage";
    if (!closeBootSnapshots(&boot_context, &boot_mapping, &boot_vram)) return "snapshots";
    boot_inputs.close();
    return null;
}

pub fn closeBootSnapshots(context: *@import("boot_context.zig").Capture, mapping: *@import("boot_mapping.zig").Capture, capture: *@import("boot_vram.zig").Capture) bool {
    return closeBootMappings(context, mapping) and capture.close();
}

fn logBootCleanup(phase: ?[]const u8) void {
    log("NVIDIA boot-abort: cleanup={s} phase={s} display-hold={d} restore-error={s} display-status={d} buffer-status={d} firmware-effects={}", .{
        if (phase == null) @as([]const u8, "OK") else "retained", phase orelse "complete", boot_vram.boot.held_generation,
        if (boot_vram.last_error) |err| @errorName(err) else "none", boot_vram.boot.last_status, boot_vram.last_status, native_device.port.effects_possible,
    });
}

const VbiosDiagnostic = struct {
    remaining: usize = 4096,
    pub fn record(self: *VbiosDiagnostic, label: []const u8, offset: usize, bytes: []const u8) void {
        var at: usize = 0;
        while (at < bytes.len and self.remaining != 0) {
            // @min narrows this to u7. Widen before doubling the hex length:
            // 64 input bytes need 128 characters, which do not fit in u7.
            const count: usize = @min(64, bytes.len - at, self.remaining);
            var hex: [128]u8 = undefined;
            const alphabet = "0123456789abcdef";
            for (bytes[at..][0..count], 0..) |byte, index| {
                hex[index * 2] = alphabet[byte >> 4];
                hex[index * 2 + 1] = alphabet[byte & 15];
            }
            log("NVIDIA vbios raw: unvalidated kind={s} offset={x} bytes={d} hex={s}", .{ label, offset + at, count, hex[0 .. count * 2] });
            at += count;
            self.remaining -= count;
        }
    }
};

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
