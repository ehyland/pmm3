const std = @import("std");
const logging = @import("logging.zig");
const paths = @import("paths.zig");
const types = @import("types.zig");

const shim_names = [_][]const u8{ "npm", "npx", "pnpm", "pnpx", "yarn", "bun", "bunx" };

pub fn run(ctx: types.Ctx, custom_rc_path: ?[]const u8) !void {
    const self_exe = try std.process.executablePathAlloc(ctx.io, ctx.allocator);
    const bin_dir = try paths.getBinDir(ctx);
    const pmm_home = try paths.getPmmDir(ctx);
    const pmm_target = try paths.getInstalledPmmPath(ctx);

    try paths.makePathAbsolute(ctx, bin_dir);
    try installBinary(ctx, self_exe, pmm_target);
    try ensureShims(ctx, bin_dir, pmm_target);
    try ensureBashrcHook(ctx, pmm_home, custom_rc_path);

    logging.friendly("Setup complete", .{});
    logging.info("Shims installed to {s}", .{try paths.formatHomeRelative(ctx, bin_dir)});
}

fn installBinary(ctx: types.Ctx, source_path: []const u8, target_path: []const u8) !void {
    if (std.mem.eql(u8, source_path, target_path)) {
        return;
    }

    const source = try std.Io.Dir.openFileAbsolute(ctx.io, source_path, .{});
    defer source.close(ctx.io);

    const target = try std.Io.Dir.createFileAbsolute(ctx.io, target_path, .{ .truncate = true, .read = true, .permissions = .executable_file });
    defer target.close(ctx.io);

    var source_reader = source.reader(ctx.io, &.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try source_reader.interface.readSliceShort(&buf);
        if (bytes_read == 0) break;
        try target.writeStreamingAll(ctx.io, buf[0..bytes_read]);
    }

    try target.setPermissions(ctx.io, std.Io.File.Permissions.fromMode(0o755));
}

fn ensureShims(ctx: types.Ctx, bin_dir: []const u8, pmm_target: []const u8) !void {
    for (shim_names) |name| {
        const shim_path = try std.fs.path.join(ctx.allocator, &.{ bin_dir, name });
        std.Io.Dir.deleteFileAbsolute(ctx.io, shim_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        try std.Io.Dir.symLinkAbsolute(ctx.io, pmm_target, shim_path, .{});
    }
}

fn ensureBashrcHook(ctx: types.Ctx, pmm_home: []const u8, custom_rc_path: ?[]const u8) !void {
    const home = try ctx.environ.getAlloc(ctx.allocator, "HOME");
    const bashrc_path = if (custom_rc_path) |path| try std.Io.Dir.realPathFileAbsoluteAlloc(ctx.io, path, ctx.allocator) else try std.fs.path.join(ctx.allocator, &.{ home, ".bashrc" });
    const hook = try std.fmt.allocPrint(
        ctx.allocator,
        "\n\n# pmm3\nexport PMM3_HOME=\"${{PMM3_HOME:-{s}}}\"\ncase \":$PATH:\" in\n  *\":$PMM3_HOME/bin:\"*) ;;\n  *) export PATH=\"$PMM3_HOME/bin:$PATH\" ;;\nesac\n",
        .{pmm_home},
    );

    const existing = try paths.readFileIfPresent(ctx, bashrc_path);
    if (existing) |content| {
        if (std.mem.find(u8, content, "# pmm3") != null or std.mem.find(u8, content, "PMM3_HOME") != null) {
            return;
        }
    }

    const file = try std.Io.Dir.createFileAbsolute(ctx.io, bashrc_path, .{ .read = true, .truncate = false });
    defer file.close(ctx.io);
    const end_offset = try file.length(ctx.io);
    try file.writePositionalAll(ctx.io, hook, end_offset);

    logging.info("Added pmm3 shell hook to {s}", .{try paths.formatHomeRelative(ctx, bashrc_path)});
}
