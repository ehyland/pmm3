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
};
