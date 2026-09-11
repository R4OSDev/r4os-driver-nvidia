const std = @import("std");

pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk = sdk_build.sdk(b, b.dependencyFromBuildZig(sdk_build, .{}), .{});
    const module = sdk.addR4MF(b.path("module.R4MF"));
    const headers = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    headers.addFileArg(b.path("Tools/VerifyNativeHeaders.ps1"));
    headers.addArg("-HeaderRoot");
    headers.addDirectoryArg(b.path("ThirdParty/Nvidia570.144"));
    headers.addArg("-LockPath");
    headers.addFileArg(b.path("src/firmware-lock.json"));
    headers.addArg("-SourceCatalogPath");
    headers.addFileArg(b.path("Tools/Rm/Sources.json"));
    module.code.generated.file.step.dependOn(&headers.step);
    const pin = @import("src/firmware.zig").lock;
    const verify = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    verify.addFileArg(b.path("Tools/VerifyFirmwarePackage.ps1"));
    verify.addArg("-LockPath");
    verify.addFileArg(b.path("src/firmware-lock.json"));
    const parameters = [_][]const u8{ "-LicensePath", "-Ga10xPath", "-Tu10xPath" };
    const names = [_][]const u8{ pin.license.resource, pin.firmware[0].resource, pin.firmware[1].resource };
    for (parameters, names) |parameter, name| {
        verify.addArg(parameter);
        verify.addFileArg(b.path(b.pathJoin(&.{ "Firmware", name })));
    }
    // Verification precedes packaging and installation, not a parallel
    // check which could publish an invalid module before reporting failure.
    module.output.generated.file.step.dependOn(&verify.step);
    const boot_parameters = [_][]const u8{ "-BootImagePath", "-BootDescriptorPath", "-BootLicensePath" };
    const boot_names = [_][]const u8{ pin.boot.image.resource, pin.boot.descriptor.resource, pin.boot.license.resource };
    for (boot_parameters, boot_names) |parameter, name| {
        verify.addArg(parameter);
        verify.addFileArg(b.path(b.pathJoin(&.{ "BootFirmware", name })));
    }
    const unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const unit_step = b.step("unit-test", "Passive PCI identity and bounded NVIDIA firmware parsing");
    unit_step.dependOn(&b.addRunArtifact(unit).step);
    const lifecycle = b.createModule(.{ .root_source_file = b.path("src/lifecycle_test.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    lifecycle.addImport("r4os", sdk.createR4osModule(b.graph.host, .ReleaseSafe));
    // Host lifecycle tests link the same C companions through the canonical
    // parser. They do not supply replacements for their private Zig providers.
    const manifest = sdk_build.build_api.module_manifest.parse(b.allocator, "module.R4MF", @embedFile("module.R4MF")) catch @panic("Invalid NVIDIA manifest");
    for (manifest.c_includes) |path| lifecycle.addIncludePath(b.path(path));
    for (manifest.c_defines) |value| lifecycle.addCMacro(value.name, value.value);
    const host_c_base = [_][]const u8{ "-ffreestanding", "-fno-builtin", "-fno-stack-protector", "-mno-red-zone" };
    const combined_flags = b.allocator.alloc([]const u8, host_c_base.len + manifest.c_flags.len) catch @panic("OOM");
    @memcpy(combined_flags[0..host_c_base.len], &host_c_base);
    @memcpy(combined_flags[host_c_base.len..], manifest.c_flags);
    for (manifest.sources[1..]) |path| lifecycle.addCSourceFile(.{ .file = b.path(path), .flags = combined_flags });
    const lifecycle_test = b.addTest(.{ .root_module = lifecycle, .filters = &.{"NVIDIA actual driver lifecycle"} });
    lifecycle_test.step.dependOn(&headers.step);
    unit_step.dependOn(&b.addRunArtifact(lifecycle_test).step);
    // The existing owner test also exercises the original-header C varargs
    // boundary against host libc. Its log sink stays in this host executable.
    const format_module = b.createModule(.{ .target = b.graph.host, .optimize = .ReleaseSafe, .link_libc = true });
    for (manifest.c_includes) |path| format_module.addIncludePath(b.path(path));
    format_module.addIncludePath(b.path("src/rm"));
    for (manifest.c_defines) |value| format_module.addCMacro(value.name, value.value);
    for ([_][]const u8{ "src/rm/os_format.c", "src/rm/nvkms_format.c", "src/rm/os_log.c", "src/rm/nvkms_log.c" }) |path|
        format_module.addCSourceFile(.{ .file = b.path(path), .flags = combined_flags });
    format_module.addCSourceFile(.{ .file = b.path("Tests/RmFormat.c"), .flags = &.{ "-std=gnu11", "-fno-builtin" } });
    const format_test = b.addExecutable(.{ .name = "rm-format-test", .root_module = format_module });
    format_test.step.dependOn(&headers.step);
    unit_step.dependOn(&b.addRunArtifact(format_test).step);
    const storage = b.createModule(.{ .root_source_file = b.path("src/firmware_storage_test.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    storage.addImport("r4os", sdk.createR4osModule(b.graph.host, .ReleaseSafe));
    unit_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = storage, .filters = &.{"firmware CPU storage"} })).step);
    const inspector = b.addExecutable(.{ .name = "nvbios-inspect", .root_module = b.createModule(.{
        .root_source_file = b.path("src/inspect.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const run = b.addRunArtifact(inspector);
    if (b.args) |args| run.addArgs(args);
    b.step("inspect-vbios", "Inspect a supplied ROM file: -- INPUT OUTPUT.json [PCI-device-hex]").dependOn(&run.step);
    const firmware_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/firmware_test.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    unit_step.dependOn(&b.addRunArtifact(firmware_test).step);
    const firmware_inspector = b.addExecutable(.{ .name = "nvfirmware-inspect", .root_module = b.createModule(.{
        .root_source_file = b.path("src/firmware_inspect.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const inspect_firmware = b.addRunArtifact(firmware_inspector);
    if (b.args) |args| inspect_firmware.addArgs(args);
    b.step("inspect-firmware", "Verify the pinned GSP container: -- INPUT FAMILY OUTPUT.json").dependOn(&inspect_firmware.step);
    const layout_inspector = b.addExecutable(.{ .name = "nvgsp-layout", .root_module = b.createModule(.{
        .root_source_file = b.path("src/gsp_layout_inspect.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const inspect_layout = b.addRunArtifact(layout_inspector);
    if (b.args) |args| inspect_layout.addArgs(args);
    b.step("inspect-gsp-layout", "Plan GA106 first boot: -- PREFLIGHT.json GSP.bin BOOT.bin DESC.bin OUTPUT.json").dependOn(&inspect_layout.step);
    const prepare = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    prepare.addFileArg(b.path("Tools/PrepareFirmware.ps1"));
    prepare.addArg("-Inspector");
    prepare.addArtifactArg(firmware_inspector);
    if (b.args) |args| prepare.addArgs(args);
    b.step("prepare-firmware", "Prepare local firmware: -- -SourceDirectory PATH -ScratchDirectory Temp/PATH [-OutputDirectory PATH]").dependOn(&prepare.step);
    const prepare_boot = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    prepare_boot.addFileArg(b.path("Tools/PrepareBootFirmware.ps1"));
    if (b.args) |args| prepare_boot.addArgs(args);
    b.step("prepare-boot-firmware", "Provision admitted boot files/notices: -- -SourceDirectory PATH -BootstrapDirectory PATH -ScratchDirectory PATH [-OutputDirectory PATH]").dependOn(&prepare_boot.step);
    const bootstrap = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    bootstrap.addFileArg(b.path("Tools/PrepareBootstrap.ps1"));
    bootstrap.addArgs(&.{ "-Compiler", b.graph.zig_exe });
    if (b.args) |args| bootstrap.addArgs(args);
    b.step("prepare-bootstrap", "Export pinned CPU reference data: -- -SourceDirectory PATH -ScratchDirectory Temp/PATH -OutputDirectory PATH").dependOn(&bootstrap.step);
    const rm_build = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    rm_build.addFileArg(b.path("Tools/BuildRm.ps1"));
    rm_build.addArgs(&.{ "-Compiler", b.graph.zig_exe });
    if (b.args) |args| rm_build.addArgs(args);
    b.step("build-rm", "Build original RM/NVKMS sources and shaders: -- -SourceDirectory PATH -ScratchDirectory Temp/PATH [-Jobs 4] [-XzPath PATH]").dependOn(&rm_build.step);
}
