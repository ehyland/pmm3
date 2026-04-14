const std = @import("std");
const logging = @import("logging.zig");

pub const RequestHeaders = []const std.http.Header;

pub fn fetchUrlToMemory(allocator: std.mem.Allocator, url: []const u8, headers: RequestHeaders) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = headers,
        .response_writer = &output.writer,
    });
    try ensureSuccessfulResponse(url, result.status);

    return try allocator.dupe(u8, output.written());
}

pub fn fetchUrlToFile(allocator: std.mem.Allocator, url: []const u8, headers: RequestHeaders, output_path: []const u8) !void {
    const output_dir = std.fs.path.dirname(output_path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(output_dir);

    const file = try std.fs.createFileAbsolute(output_path, .{ .truncate = true, .read = true });
    defer file.close();

    var file_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    var client: std.http.Client = .{ .allocator = allocator };
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
