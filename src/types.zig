const std = @import("std");

pub const Ctx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
};

pub const PackageManagerSpec = struct {
    name: []const u8,
    version: []const u8,
};

pub const FoundSpec = struct {
    package_json_path: []const u8,
    spec: PackageManagerSpec,
};

pub const Shim = struct {
    package_manager_name: []const u8,
    executable_name: []const u8,
    allow_spec_mismatch: bool = false,
};
