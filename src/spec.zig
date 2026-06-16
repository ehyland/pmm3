const std = @import("std");
const types = @import("types.zig");

pub const supported_package_managers = [_][]const u8{ "pnpm", "npm", "yarn", "bun" };

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    prerelease: ?[]const u8 = null,
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

pub fn getVersionCore(version: []const u8) ![]const u8 {
    const plus_index = std.mem.findScalar(u8, version, '+') orelse return version;
    const suffix = version[plus_index + 1 ..];

    if (!std.mem.startsWith(u8, suffix, "sha")) return error.InvalidVersion;

    return version[0..plus_index];
}

pub fn parseVersion(version: []const u8) !Version {
    const core = try getVersionCore(version);
    const prerelease_index = std.mem.findScalar(u8, core, '-');
    const release_core = if (prerelease_index) |index| core[0..index] else core;
    const prerelease = if (prerelease_index) |index| blk: {
        const value = core[index + 1 ..];
        try validatePrerelease(value);
        break :blk value;
    } else null;

    var parts = std.mem.splitScalar(u8, release_core, '.');
    const major = parts.next() orelse return error.InvalidVersion;
    const minor = parts.next() orelse return error.InvalidVersion;
    const patch = parts.next() orelse return error.InvalidVersion;
    if (parts.next() != null) return error.InvalidVersion;

    return .{
        .major = try std.fmt.parseInt(u32, major, 10),
        .minor = try std.fmt.parseInt(u32, minor, 10),
        .patch = try std.fmt.parseInt(u32, patch, 10),
        .prerelease = prerelease,
    };
}

pub fn compareVersions(left: Version, right: Version) i8 {
    if (left.major < right.major) return -1;
    if (left.major > right.major) return 1;
    if (left.minor < right.minor) return -1;
    if (left.minor > right.minor) return 1;
    if (left.patch < right.patch) return -1;
    if (left.patch > right.patch) return 1;

    if (left.prerelease == null and right.prerelease == null) return 0;
    if (left.prerelease == null) return 1;
    if (right.prerelease == null) return -1;

    return comparePrerelease(left.prerelease.?, right.prerelease.?);
}

fn validatePrerelease(prerelease: []const u8) !void {
    if (prerelease.len == 0) return error.InvalidVersion;

    var identifiers = std.mem.splitScalar(u8, prerelease, '.');
    while (identifiers.next()) |identifier| {
        if (identifier.len == 0) return error.InvalidVersion;

        for (identifier) |char| {
            if (!isValidPrereleaseIdentifierChar(char)) return error.InvalidVersion;
        }

        if (isNumericIdentifier(identifier) and identifier.len > 1 and identifier[0] == '0') {
            return error.InvalidVersion;
        }
    }
}

fn comparePrerelease(left: []const u8, right: []const u8) i8 {
    var left_parts = std.mem.splitScalar(u8, left, '.');
    var right_parts = std.mem.splitScalar(u8, right, '.');

    while (true) {
        const left_part = left_parts.next();
        const right_part = right_parts.next();

        if (left_part == null and right_part == null) return 0;
        if (left_part == null) return -1;
        if (right_part == null) return 1;

        const comparison = comparePrereleaseIdentifier(left_part.?, right_part.?);
        if (comparison != 0) return comparison;
    }
}

fn comparePrereleaseIdentifier(left: []const u8, right: []const u8) i8 {
    const left_is_numeric = isNumericIdentifier(left);
    const right_is_numeric = isNumericIdentifier(right);

    if (left_is_numeric and right_is_numeric) {
        if (left.len < right.len) return -1;
        if (left.len > right.len) return 1;

        return switch (std.mem.order(u8, left, right)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    if (left_is_numeric) return -1;
    if (right_is_numeric) return 1;

    return switch (std.mem.order(u8, left, right)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn isNumericIdentifier(value: []const u8) bool {
    if (value.len == 0) return false;

    for (value) |char| {
        if (char < '0' or char > '9') return false;
    }

    return true;
}

fn isValidPrereleaseIdentifierChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '-';
}

pub fn getShim(name: []const u8) ?types.Shim {
    if (std.mem.eql(u8, name, "pmm3")) {
        return .{ .package_manager_name = "pmm3", .executable_name = "pmm3" };
    }
    if (std.mem.eql(u8, name, "npm")) {
        return .{ .package_manager_name = "npm", .executable_name = "npm" };
    }
    if (std.mem.eql(u8, name, "npx")) {
        return .{ .package_manager_name = "npm", .executable_name = "npx", .allow_spec_mismatch = true };
    }
    if (std.mem.eql(u8, name, "pnpm")) {
        return .{ .package_manager_name = "pnpm", .executable_name = "pnpm" };
    }
    if (std.mem.eql(u8, name, "pnpx")) {
        return .{ .package_manager_name = "pnpm", .executable_name = "pnpx", .allow_spec_mismatch = true };
    }
    if (std.mem.eql(u8, name, "yarn")) {
        return .{ .package_manager_name = "yarn", .executable_name = "yarn" };
    }
    if (std.mem.eql(u8, name, "bun")) {
        return .{ .package_manager_name = "bun", .executable_name = "bun" };
    }
    if (std.mem.eql(u8, name, "bunx")) {
        return .{ .package_manager_name = "bun", .executable_name = "bun", .allow_spec_mismatch = true };
    }
    return null;
}

pub fn isNativePackageManager(name: []const u8) bool {
    return std.mem.eql(u8, name, "bun");
}

test "getShim marks npx pnpx bunx as allow_spec_mismatch" {
    try std.testing.expect(getShim("npx").?.allow_spec_mismatch);
    try std.testing.expect(getShim("pnpx").?.allow_spec_mismatch);
    try std.testing.expect(getShim("bunx").?.allow_spec_mismatch);
}

test "getShim leaves primary package manager shims as not allow_spec_mismatch" {
    try std.testing.expect(!getShim("npm").?.allow_spec_mismatch);
    try std.testing.expect(!getShim("pnpm").?.allow_spec_mismatch);
    try std.testing.expect(!getShim("yarn").?.allow_spec_mismatch);
    try std.testing.expect(!getShim("bun").?.allow_spec_mismatch);
    try std.testing.expect(!getShim("pmm3").?.allow_spec_mismatch);
}

test "parse version" {
    const parsed = try parseVersion("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), parsed.major);
    try std.testing.expectEqual(@as(u32, 2), parsed.minor);
    try std.testing.expectEqual(@as(u32, 3), parsed.patch);
    try std.testing.expect(parsed.prerelease == null);
}

test "parse prerelease version" {
    const parsed = try parseVersion("1.2.3-alpha.1");
    try std.testing.expectEqual(@as(u32, 1), parsed.major);
    try std.testing.expectEqual(@as(u32, 2), parsed.minor);
    try std.testing.expectEqual(@as(u32, 3), parsed.patch);
    try std.testing.expectEqualStrings("alpha.1", parsed.prerelease.?);
}

test "parse version with sha suffix" {
    const parsed = try parseVersion("3.2.3+sha224.953c8233f7a92884eee2de69a1b92d1f2ec1655e66d08071ba9a02fa");
    try std.testing.expectEqual(@as(u32, 3), parsed.major);
    try std.testing.expectEqual(@as(u32, 2), parsed.minor);
    try std.testing.expectEqual(@as(u32, 3), parsed.patch);
    try std.testing.expect(parsed.prerelease == null);
}

test "parse prerelease version with sha suffix" {
    const parsed = try parseVersion("3.2.3-alpha.2+sha224.953c8233f7a92884eee2de69a1b92d1f2ec1655e66d08071ba9a02fa");
    try std.testing.expectEqual(@as(u32, 3), parsed.major);
    try std.testing.expectEqual(@as(u32, 2), parsed.minor);
    try std.testing.expectEqual(@as(u32, 3), parsed.patch);
    try std.testing.expectEqualStrings("alpha.2", parsed.prerelease.?);
}

test "parse spec string preserves sha suffix" {
    const parsed = try parseSpecString("yarn@3.2.3+sha224.953c8233f7a92884eee2de69a1b92d1f2ec1655e66d08071ba9a02fa");
    try std.testing.expectEqualStrings("yarn", parsed.name);
    try std.testing.expectEqualStrings("3.2.3+sha224.953c8233f7a92884eee2de69a1b92d1f2ec1655e66d08071ba9a02fa", parsed.version);
}

test "reject non-sha build metadata" {
    try std.testing.expectError(error.InvalidVersion, parseVersion("3.2.3+build.1"));
}

test "reject prerelease numeric identifiers with leading zeroes" {
    try std.testing.expectError(error.InvalidVersion, parseVersion("1.2.3-alpha.01"));
}

test "compare versions respects prerelease precedence" {
    try std.testing.expect(compareVersions(try parseVersion("1.2.3-alpha.1"), try parseVersion("1.2.3-alpha.2")) < 0);
    try std.testing.expect(compareVersions(try parseVersion("1.2.3-alpha.2"), try parseVersion("1.2.3-beta.1")) < 0);
    try std.testing.expect(compareVersions(try parseVersion("1.2.3-alpha.1"), try parseVersion("1.2.3")) < 0);
    try std.testing.expect(compareVersions(try parseVersion("1.2.4-alpha.1"), try parseVersion("1.2.3")) > 0);
    try std.testing.expectEqual(@as(i8, 0), compareVersions(try parseVersion("1.2.3-alpha.1"), try parseVersion("1.2.3-alpha.1")));
}
