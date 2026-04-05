const std = @import("std");
const types = @import("types.zig");

pub const supported_package_managers = [_][]const u8{ "pnpm", "npm", "yarn" };

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

pub fn isSupportedPackageManager(name: []const u8) bool {
    inline for (supported_package_managers) |supported| {
        if (std.mem.eql(u8, name, supported)) return true;
    }
    return false;
}

pub fn parseSpecString(spec_string: []const u8) !types.PackageManagerSpec {
    const at_index = std.mem.lastIndexOfScalar(u8, spec_string, '@') orelse return error.InvalidSpec;
    const name = spec_string[0..at_index];
    const version = spec_string[at_index + 1 ..];

    if (!isSupportedPackageManager(name)) return error.UnsupportedPackageManager;
    _ = try parseVersion(version);

    return .{ .name = name, .version = version };
}

pub fn parseVersion(version: []const u8) !Version {
    var parts = std.mem.splitScalar(u8, version, '.');
    const major = parts.next() orelse return error.InvalidVersion;
    const minor = parts.next() orelse return error.InvalidVersion;
    const patch = parts.next() orelse return error.InvalidVersion;
    if (parts.next() != null) return error.InvalidVersion;

    return .{
        .major = try std.fmt.parseInt(u32, major, 10),
        .minor = try std.fmt.parseInt(u32, minor, 10),
        .patch = try std.fmt.parseInt(u32, patch, 10),
    };
}

pub fn getShim(name: []const u8) ?types.Shim {
    if (std.mem.eql(u8, name, "pmm3")) {
        return .{ .package_manager_name = "pmm3", .executable_name = "pmm3" };
    }
    if (std.mem.eql(u8, name, "npm")) {
        return .{ .package_manager_name = "npm", .executable_name = "npm" };
    }
    if (std.mem.eql(u8, name, "npx")) {
        return .{ .package_manager_name = "npm", .executable_name = "npx" };
    }
    if (std.mem.eql(u8, name, "pnpm")) {
        return .{ .package_manager_name = "pnpm", .executable_name = "pnpm" };
    }
    if (std.mem.eql(u8, name, "pnpx")) {
        return .{ .package_manager_name = "pnpm", .executable_name = "pnpx" };
    }
    if (std.mem.eql(u8, name, "yarn")) {
        return .{ .package_manager_name = "yarn", .executable_name = "yarn" };
    }
    return null;
}

test "parse version" {
    const parsed = try parseVersion("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), parsed.major);
    try std.testing.expectEqual(@as(u32, 2), parsed.minor);
    try std.testing.expectEqual(@as(u32, 3), parsed.patch);
}
