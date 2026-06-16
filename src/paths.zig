const std = @import("std");
const types = @import("types.zig");

pub const max_file_bytes = 1024 * 1024;

pub fn getRegistry(ctx: types.Ctx) ![]const u8 {
    const from_env = ctx.environ.getAlloc(ctx.allocator, "PMM_NPM_REGISTRY") catch null;
    const raw = from_env orelse try ctx.allocator.dupe(u8, "https://registry.npmjs.org");
    return trimTrailingSlash(raw);
}

pub fn getPmmDir(ctx: types.Ctx) ![]const u8 {
    if (ctx.environ.getAlloc(ctx.allocator, "PMM3_HOME")) |value| {
        return value;
    } else |_| {}

    const home = try ctx.environ.getAlloc(ctx.allocator, "HOME");
    return try std.fs.path.join(ctx.allocator, &.{ home, ".pmm3" });
}

pub fn getBinDir(ctx: types.Ctx) ![]const u8 {
    return try std.fs.path.join(ctx.allocator, &.{ try getPmmDir(ctx), "bin" });
}

pub fn getInstalledPmmPath(ctx: types.Ctx) ![]const u8 {
    return try std.fs.path.join(ctx.allocator, &.{ try getBinDir(ctx), "pmm3" });
}

pub fn getInstallPath(ctx: types.Ctx, package_spec: types.PackageManagerSpec) ![]const u8 {
    const pmm_dir = try getPmmDir(ctx);
    const folder_name = try std.fmt.allocPrint(ctx.allocator, "{s}-{s}", .{ package_spec.name, package_spec.version });
    return try std.fs.path.join(ctx.allocator, &.{ pmm_dir, "installed-versions", folder_name });
}

pub fn getInstallPackageJsonPath(ctx: types.Ctx, package_spec: types.PackageManagerSpec) ![]const u8 {
    return try std.fs.path.join(ctx.allocator, &.{ try getInstallPath(ctx, package_spec), "package.json" });
}

pub fn getDefaultFilePath(ctx: types.Ctx, package_manager_name: []const u8) ![]const u8 {
    const file_name = try std.fmt.allocPrint(ctx.allocator, "{s}-version", .{package_manager_name});
    return try std.fs.path.join(ctx.allocator, &.{ try getPmmDir(ctx), "installed-versions", ".defaults", file_name });
}

pub fn readFileIfPresent(ctx: types.Ctx, absolute_path: []const u8) !?[]u8 {
    return std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), ctx.io, absolute_path, ctx.allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub fn makePathAbsolute(ctx: types.Ctx, absolute_path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(ctx.io, absolute_path);
}

pub fn removeTreeAbsoluteIfPresent(ctx: types.Ctx, absolute_path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(ctx.io, absolute_path) catch {};
}

pub fn ignoreSpecMismatch(ctx: types.Ctx) bool {
    const value = ctx.environ.getAlloc(ctx.allocator, "PMM_IGNORE_SPEC_MISS_MATCH") catch return false;
    const lowered = std.ascii.allocLowerString(ctx.allocator, value) catch return false;
    return std.mem.eql(u8, lowered, "1") or std.mem.eql(u8, lowered, "true") or std.mem.eql(u8, lowered, "yes");
}

fn trimTrailingSlash(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

pub fn formatHomeRelative(ctx: types.Ctx, path: []const u8) ![]const u8 {
    const home = ctx.environ.getAlloc(ctx.allocator, "HOME") catch return try ctx.allocator.dupe(u8, path);
    if (std.mem.startsWith(u8, path, home)) {
        return try std.fmt.allocPrint(ctx.allocator, "~{s}", .{path[home.len..]});
    }
    return try ctx.allocator.dupe(u8, path);
}
