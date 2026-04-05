const std = @import("std");

pub fn printUsage() void {
    const message =
        \\pmm3 - Package Manager Manager, rewritten in Zig
        \\
        \\Commands:
        \\  pmm3 update-local
        \\  pmm3 update-default [package-manager] [version]
        \\  pmm3 update-self
        \\  pmm3 setup
        \\  pmm3 pin <package-manager> <path-to-package>
        \\
        \\Shims:
        \\  npm, npx, pnpm, pnpx, yarn
        \\
    ;

    std.debug.print("{s}", .{message});
}

pub fn writeRaw(message: []const u8) void {
    std.debug.print("{s}", .{message});
}

pub fn friendly(comptime format: []const u8, args: anytype) void {
    std.debug.print("🎁  " ++ format ++ "\n", args);
}

pub fn info(comptime format: []const u8, args: anytype) void {
    std.debug.print(format ++ "\n", args);
}

pub fn userError(message: []const u8) void {
    std.debug.print("⚠️  {s}\n", .{message});
}

pub fn userErrorFmt(comptime format: []const u8, args: anytype) void {
    std.debug.print("⚠️  " ++ format ++ "\n", args);
}
