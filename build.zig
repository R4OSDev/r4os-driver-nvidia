const std = @import("std");

pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk = sdk_build.sdk(b, b.dependencyFromBuildZig(sdk_build, .{}), .{});
    const module = sdk.addR4MF(b.path("module.R4MF"));
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
    const unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const unit_step = b.step("unit-test", "Passive PCI identity and bounded NVIDIA firmware parsing");
    unit_step.dependOn(&b.addRunArtifact(unit).step);
    const lifecycle = b.createModule(.{ .root_source_file = b.path("src/lifecycle_test.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    lifecycle.addImport("r4os", sdk.createR4osModule(b.graph.host, .ReleaseSafe));
    const lifecycle_test = b.addTest(.{ .root_module = lifecycle, .filters = &.{"NVIDIA actual driver lifecycle"} });
    unit_step.dependOn(&b.addRunArtifact(lifecycle_test).step);
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
    const prepare = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    prepare.addFileArg(b.path("Tools/PrepareFirmware.ps1"));
    prepare.addArg("-Inspector");
    prepare.addArtifactArg(firmware_inspector);
    if (b.args) |args| prepare.addArgs(args);
    b.step("prepare-firmware", "Prepare local firmware: -- -SourceDirectory PATH -ScratchDirectory Temp/PATH [-OutputDirectory PATH]").dependOn(&prepare.step);
    const rm_build = b.addSystemCommand(&.{ "pwsh", "-NoProfile", "-File" });
    rm_build.addFileArg(b.path("Tools/BuildRm.ps1"));
    rm_build.addArgs(&.{ "-Compiler", b.graph.zig_exe });
    if (b.args) |args| rm_build.addArgs(args);
    b.step("build-rm", "Build original RM/NVKMS sources and shaders: -- -SourceDirectory PATH -ScratchDirectory Temp/PATH [-Jobs 4] [-XzPath PATH]").dependOn(&rm_build.step);
}
