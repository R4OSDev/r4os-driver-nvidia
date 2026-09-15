// The build and reset diagnostics read the same canonical module manifest.
const std = @import("std");
pub const version: []const u8 = blk: {
    @setEvalBranchQuota(20000);
    var lines = std.mem.splitScalar(u8, @embedFile("module.R4MF"), '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "VERSION=")) {
            if (found != null) @compileError("Duplicate NVIDIA module version");
            found = line["VERSION=".len..];
        }
    }
    break :blk found orelse @compileError("Missing NVIDIA module version");
};
