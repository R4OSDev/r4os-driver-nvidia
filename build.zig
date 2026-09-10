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
    b.step("unit-test", "Passive PCI identity and bounded NVIDIA firmware parsing").dependOn(&b.addRunArtifact(unit).step);
    const inspector = b.addExecutable(.{ .name = "nvbios-inspect", .root_module = b.createModule(.{
        .root_source_file = b.path("src/inspect.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const run = b.addRunArtifact(inspector);
    if (b.args) |args| run.addArgs(args);
    b.step("inspect-vbios", "Inspect a supplied ROM file: -- INPUT OUTPUT.json [PCI-device-hex]").dependOn(&run.step);
}
