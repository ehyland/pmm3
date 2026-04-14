const std = @import("std");
const logging = @import("logging.zig");
const paths = @import("paths.zig");

const shim_names = [_][]const u8{ "npm", "npx", "pnpm", "pnpx", "yarn", "bun", "bunx" };

pub fn run(allocator: std.mem.Allocator, custom_rc_path: ?[]const u8) !void {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    const bin_dir = try paths.getBinDir(allocator);
    const pmm_home = try paths.getPmmDir(allocator);
    const pmm_target = try paths.getInstalledPmmPath(allocator);

    try paths.makePathAbsolute(allocator, bin_dir);
    try installBinary(self_exe, pmm_target);
    try ensureShims(allocator, bin_dir, pmm_target);
    try ensureBashrcHook(allocator, pmm_home, custom_rc_path);

    logging.friendly("Setup complete", .{});
    logging.info("Shims installed to {s}", .{try paths.formatHomeRelative(allocator, bin_dir)});
}

fn installBinary(source_path: []const u8, target_path: []const u8) !void {
    if (std.mem.eql(u8, source_path, target_path)) {
        // Avoid reopening the currently executing binary for write access.
        // On macOS that can fail with FileBusy during first install.
        return;
    }

    const source = try std.fs.openFileAbsolute(source_path, .{});
    defer source.close();

    const target = try std.fs.createFileAbsolute(target_path, .{ .truncate = true, .read = true, .mode = 0o755 });
    defer target.close();

    var buffer: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try source.read(&buffer);
        if (bytes_read == 0) break;
        try target.writeAll(buffer[0..bytes_read]);
    }

    try target.chmod(0o755);
}
fn ensureShims(allocator: std.mem.Allocator, bin_dir: []const u8, pmm_target: []const u8) !void {
    for (shim_names) |name| {
        const shim_path = try std.fs.path.join(allocator, &.{ bin_dir, name });
        std.fs.deleteFileAbsolute(shim_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        // Point each shim at the installed binary so setup works from any working directory.
        try std.fs.symLinkAbsolute(pmm_target, shim_path, .{});
    }
}

fn ensureBashrcHook(allocator: std.mem.Allocator, pmm_home: []const u8, custom_rc_path: ?[]const u8) !void {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    const bashrc_path = if (custom_rc_path) |path| try std.fs.realpathAlloc(allocator, path) else try std.fs.path.join(allocator, &.{ home, ".bashrc" });
    const hook = try std.fmt.allocPrint(
        allocator,
        "\n\n# pmm3\nexport PMM3_HOME=\"${{PMM3_HOME:-{s}}}\"\ncase \":$PATH:\" in\n  *\":$PMM3_HOME/bin:\"*) ;;\n  *) export PATH=\"$PMM3_HOME/bin:$PATH\" ;;\nesac\n",
        .{pmm_home},
    );

    const existing = try paths.readFileIfPresent(allocator, bashrc_path);
    if (existing) |content| {
        if (std.mem.indexOf(u8, content, "# pmm3") != null or std.mem.indexOf(u8, content, "PMM3_HOME") != null) {
            return;
        }
    }

    const file = try std.fs.createFileAbsolute(bashrc_path, .{ .read = true, .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(hook);

    logging.info("Added pmm3 shell hook to {s}", .{try paths.formatHomeRelative(allocator, bashrc_path)});
}
