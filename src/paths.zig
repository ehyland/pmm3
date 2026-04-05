const std = @import("std");
const types = @import("types.zig");

pub const max_file_bytes = 1024 * 1024;

pub fn getRegistry(allocator: std.mem.Allocator) ![]const u8 {
    const from_env = std.process.getEnvVarOwned(allocator, "PMM_NPM_REGISTRY") catch null;
    const raw = from_env orelse try allocator.dupe(u8, "https://registry.npmjs.org");
    return trimTrailingSlash(raw);
}

pub fn getPmmDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "PMM3_HOME")) |value| {
        return value;
    } else |_| {}

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    return try std.fs.path.join(allocator, &.{ home, ".pmm3" });
}

pub fn getBinDir(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ try getPmmDir(allocator), "bin" });
}

pub fn getInstalledPmmPath(allocator: std.mem.Allocator) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ try getBinDir(allocator), "pmm3" });
}

pub fn getInstallPath(allocator: std.mem.Allocator, package_spec: types.PackageManagerSpec) ![]const u8 {
    const pmm_dir = try getPmmDir(allocator);
    const folder_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ package_spec.name, package_spec.version });
    return try std.fs.path.join(allocator, &.{ pmm_dir, "installed-versions", folder_name });
}

pub fn getInstallPackageJsonPath(allocator: std.mem.Allocator, package_spec: types.PackageManagerSpec) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ try getInstallPath(allocator, package_spec), "package.json" });
}

pub fn getDefaultFilePath(allocator: std.mem.Allocator, package_manager_name: []const u8) ![]const u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}-version", .{package_manager_name});
    return try std.fs.path.join(allocator, &.{ try getPmmDir(allocator), "installed-versions", ".defaults", file_name });
}

pub fn readFileIfPresent(allocator: std.mem.Allocator, absolute_path: []const u8) !?[]u8 {
    const file = std.fs.openFileAbsolute(absolute_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    return try file.readToEndAlloc(allocator, max_file_bytes);
}

pub fn makePathAbsolute(_: std.mem.Allocator, absolute_path: []const u8) !void {
    try std.fs.cwd().makePath(absolute_path);
}

pub fn removeTreeAbsoluteIfPresent(_: std.mem.Allocator, absolute_path: []const u8) !void {
    std.fs.deleteTreeAbsolute(absolute_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn ignoreSpecMismatch(allocator: std.mem.Allocator) bool {
    const value = std.process.getEnvVarOwned(allocator, "PMM_IGNORE_SPEC_MISS_MATCH") catch return false;
    const lowered = std.ascii.allocLowerString(allocator, value) catch return false;
    return std.mem.eql(u8, lowered, "1") or std.mem.eql(u8, lowered, "true") or std.mem.eql(u8, lowered, "yes");
}

fn trimTrailingSlash(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

pub fn formatHomeRelative(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return try allocator.dupe(u8, path);
    if (std.mem.startsWith(u8, path, home)) {
        return try std.fmt.allocPrint(allocator, "~{s}", .{path[home.len..]});
    }
    return try allocator.dupe(u8, path);
}
