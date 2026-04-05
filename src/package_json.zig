const std = @import("std");
const spec = @import("spec.zig");
const types = @import("types.zig");

pub fn findPackageManagerSpec(allocator: std.mem.Allocator) !?types.FoundSpec {
    var current = try std.process.getCwdAlloc(allocator);

    while (true) {
        const package_json_path = try std.fs.path.join(allocator, &.{ current, "package.json" });

        if (try readPackageManagerField(allocator, package_json_path)) |field| {
            return .{
                .package_json_path = package_json_path,
                .spec = try spec.parseSpecString(field),
            };
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = try allocator.dupe(u8, parent);
    }

    return null;
}

pub fn readPackageManagerField(allocator: std.mem.Allocator, package_json_path: []const u8) !?[]const u8 {
    const parsed = (try parsePackageJson(allocator, package_json_path)) orelse return null;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidPackageJson,
    };

    const field = switch (root.get("packageManager") orelse return null) {
        .string => |value| value,
        else => return null,
    };

    const trimmed = std.mem.trim(u8, field, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

pub fn writePackageManagerField(
    allocator: std.mem.Allocator,
    package_json_path: []const u8,
    package_spec: types.PackageManagerSpec,
) !void {
    const spec_string = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ package_spec.name, package_spec.version });
    var parsed = (try parsePackageJson(allocator, package_json_path)) orelse return error.FileNotFound;
    defer parsed.deinit();

    switch (parsed.value) {
        .object => |*object| try object.put("packageManager", .{ .string = spec_string }),
        else => return error.InvalidPackageJson,
    }

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');

    const file = try std.fs.createFileAbsolute(package_json_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(output.written());
}

pub fn readPackageExecutablePath(
    allocator: std.mem.Allocator,
    package_json_path: []const u8,
    executable_name: []const u8,
) !?[]const u8 {
    const parsed = (try parsePackageJson(allocator, package_json_path)) orelse return null;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidPackageJson,
    };

    const bin_field = root.get("bin") orelse return null;
    const relative_path = switch (bin_field) {
        .string => |value| value,
        .object => |object| switch (object.get(executable_name) orelse return null) {
            .string => |value| value,
            else => return null,
        },
        else => return null,
    };

    return try allocator.dupe(u8, relative_path);
}

pub fn checkPackageExists(allocator: std.mem.Allocator, package_dir: []const u8) !bool {
    const package_json_path = try std.fs.path.join(allocator, &.{ package_dir, "package.json" });

    const file = std.fs.openFileAbsolute(package_json_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();
    return true;
}

fn parsePackageJson(allocator: std.mem.Allocator, package_json_path: []const u8) !?std.json.Parsed(std.json.Value) {
    const raw = readPackageJsonFile(allocator, package_json_path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(raw);

    return try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .use_last,
    });
}

fn readPackageJsonFile(allocator: std.mem.Allocator, package_json_path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(package_json_path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}
