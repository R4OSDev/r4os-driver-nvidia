const std = @import("std");

pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk = sdk_build.sdk(b, b.dependencyFromBuildZig(sdk_build, .{}), .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));
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
    b.step("prepare-firmware", "Prepare local firmware: -- -SourceDirectory PATH -OutputDirectory PATH -ScratchDirectory Temp/PATH").dependOn(&prepare.step);
}
