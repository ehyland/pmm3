const std = @import("std");
const logging = @import("logging.zig");
const types = @import("types.zig");

pub const RequestHeaders = []const std.http.Header;

fn isRetryableStatus(status: std.http.Status) bool {
    return switch (@intFromEnum(status)) {
        400, 408, 425, 429, 500, 502, 503, 504 => true,
        else => false,
    };
}

pub fn retryDelayMs(attempt: u32) u32 {
    return switch (attempt) {
        0 => 1000,
        1 => 2000,
        else => 4000,
    };
}

fn retrySleep(io: std.Io, attempt: u32) void {
    const ms: i64 = retryDelayMs(attempt);
    const clock_duration = std.Io.Clock.Duration{
        .raw = std.Io.Duration.fromMilliseconds(ms),
        .clock = .real,
    };
    clock_duration.sleep(io) catch {};
}

pub fn fetchUrlToMemory(ctx: types.Ctx, url: []const u8, headers: RequestHeaders) ![]u8 {
    const max_attempts: u32 = 3;
    var attempt: u32 = 0;

    while (attempt < max_attempts) : (attempt += 1) {
        if (attempt > 0) retrySleep(ctx.io, attempt - 1);

        var client: std.http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
        defer client.deinit();

        var output: std.Io.Writer.Allocating = .init(ctx.allocator);
        defer output.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .extra_headers = headers,
            .response_writer = &output.writer,
        }) catch |err| {
            if (attempt == max_attempts - 1) return err;
            continue;
        };

        const status_code = @intFromEnum(result.status);
        if (status_code >= 200 and status_code < 300) {
            return try ctx.allocator.dupe(u8, output.written());
        }

        if (attempt < max_attempts - 1 and isRetryableStatus(result.status)) {
            logging.userErrorFmt("HTTP {d} while requesting {s}, retrying...", .{ status_code, url });
            continue;
        }

        logging.userErrorFmt("HTTP {d} while requesting {s}", .{ status_code, url });
        return error.CommandFailed;
    }

    unreachable;
}

pub fn fetchUrlToFile(ctx: types.Ctx, url: []const u8, headers: RequestHeaders, output_path: []const u8) !void {
    const max_attempts: u32 = 3;
    var attempt: u32 = 0;

    while (attempt < max_attempts) : (attempt += 1) {
        if (attempt > 0) retrySleep(ctx.io, attempt - 1);

        const output_dir = std.fs.path.dirname(output_path) orelse return error.InvalidPath;
        try std.Io.Dir.cwd().createDirPath(ctx.io, output_dir);

        const file = try std.Io.Dir.createFileAbsolute(ctx.io, output_path, .{ .truncate = true, .read = true });
        defer file.close(ctx.io);

        var file_buffer: [4096]u8 = undefined;
        var file_writer = file.writer(ctx.io, &file_buffer);

        var client: std.http.Client = .{ .allocator = ctx.allocator, .io = ctx.io };
        defer client.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .extra_headers = headers,
            .response_writer = &file_writer.interface,
        }) catch |err| {
            if (attempt == max_attempts - 1) return err;
            continue;
        };
        try file_writer.interface.flush();

        const status_code = @intFromEnum(result.status);
        if (status_code >= 200 and status_code < 300) return;

        if (attempt < max_attempts - 1 and isRetryableStatus(result.status)) {
            logging.userErrorFmt("HTTP {d} while requesting {s}, retrying...", .{ status_code, url });
            continue;
        }

        logging.userErrorFmt("HTTP {d} while requesting {s}", .{ status_code, url });
        return error.CommandFailed;
    }

    unreachable;
}

test "isRetryableStatus retries on transient server and rate limit responses" {
    try std.testing.expect(isRetryableStatus(@enumFromInt(400)));
    try std.testing.expect(isRetryableStatus(@enumFromInt(408)));
    try std.testing.expect(isRetryableStatus(@enumFromInt(425)));
    try std.testing.expect(isRetryableStatus(@enumFromInt(429)));
    try std.testing.expect(isRetryableStatus(@enumFromInt(500)));
    try std.testing.expect(isRetryableStatus(@enumFromInt(502)));
    try std.testing.expect(isRetryableStatus(@enumFromInt(503)));
    try std.testing.expect(isRetryableStatus(@enumFromInt(504)));
}

test "isRetryableStatus does not retry on success or permanent client errors" {
    try std.testing.expect(!isRetryableStatus(@enumFromInt(200)));
    try std.testing.expect(!isRetryableStatus(@enumFromInt(201)));
    try std.testing.expect(!isRetryableStatus(@enumFromInt(204)));
    try std.testing.expect(!isRetryableStatus(@enumFromInt(301)));
    try std.testing.expect(!isRetryableStatus(@enumFromInt(302)));
    try std.testing.expect(!isRetryableStatus(@enumFromInt(401)));
    try std.testing.expect(!isRetryableStatus(@enumFromInt(403)));
    try std.testing.expect(!isRetryableStatus(@enumFromInt(404)));
    try std.testing.expect(!isRetryableStatus(@enumFromInt(410)));
    try std.testing.expect(!isRetryableStatus(@enumFromInt(418)));
}

test "retryDelayMs grows exponentially and caps at the largest attempt" {
    try std.testing.expectEqual(@as(u32, 1000), retryDelayMs(0));
    try std.testing.expectEqual(@as(u32, 2000), retryDelayMs(1));
    try std.testing.expectEqual(@as(u32, 4000), retryDelayMs(2));
    try std.testing.expectEqual(@as(u32, 4000), retryDelayMs(5));
}
