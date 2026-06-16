const std = @import("std");
const logging = @import("logging.zig");
const types = @import("types.zig");

pub const RequestHeaders = []const std.http.Header;

pub fn fetchUrlToMemory(ctx: types.Ctx, url: []const u8, headers: RequestHeaders) ![]u8 {
    var client: std.http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    var output: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer output.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = headers,
        .response_writer = &output.writer,
    });
    try ensureSuccessfulResponse(url, result.status);

    return try ctx.allocator.dupe(u8, output.written());
}

pub fn fetchUrlToFile(ctx: types.Ctx, url: []const u8, headers: RequestHeaders, output_path: []const u8) !void {
    const output_dir = std.fs.path.dirname(output_path) orelse return error.InvalidPath;
    try std.Io.Dir.cwd().createDirPath(ctx.io, output_dir);

    const file = try std.Io.Dir.createFileAbsolute(ctx.io, output_path, .{ .truncate = true, .read = true });
    defer file.close(ctx.io);

    var file_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(ctx.io, &file_buffer);

    var client: std.http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = headers,
        .response_writer = &file_writer.interface,
    });
    try file_writer.interface.flush();
    try ensureSuccessfulResponse(url, result.status);
}

fn ensureSuccessfulResponse(url: []const u8, status: std.http.Status) !void {
    const status_code = @intFromEnum(status);
    if (status_code >= 200 and status_code < 300) return;

    logging.userErrorFmt("HTTP {d} while requesting {s}", .{ status_code, url });
    return error.CommandFailed;
}
