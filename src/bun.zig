const std = @import("std");
const builtin = @import("builtin");
const http = @import("http.zig");
const logging = @import("logging.zig");
const paths = @import("paths.zig");
const process_utils = @import("process_utils.zig");
const spec = @import("spec.zig");
const types = @import("types.zig");

const bun_latest_release_api = "https://api.github.com/repos/oven-sh/bun/releases/latest";
const bun_download_repo = "https://github.com/oven-sh/bun";

const GitHubReleaseAsset = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

const GitHubLatestRelease = struct {
    tag_name: []const u8,
    assets: []GitHubReleaseAsset,
};

const RequestHeaders = []const std.http.Header;

const default_request_headers = [_]std.http.Header{
    .{ .name = "User-Agent", .value = "pmm3" },
};

const github_api_headers = [_]std.http.Header{
    .{ .name = "Accept", .value = "application/vnd.github+json" },
    .{ .name = "User-Agent", .value = "pmm3" },
};

const package_manager_subcommands = [_][]const u8{
    "install",
    "add",
    "remove",
    "update",
    "audit",
    "outdated",
    "link",
    "unlink",
    "publish",
};

pub fn requiresMatchingProjectSpec(argv: []const []const u8) bool {
    if (argv.len < 2) return false;

    const subcommand = argv[1];
    inline for (package_manager_subcommands) |managed| {
        if (std.mem.eql(u8, subcommand, managed)) return true;
    }

    return false;
}

pub fn getLatestVersion(allocator: std.mem.Allocator) !types.PackageManagerSpec {
    const release = try fetchLatestBunRelease(allocator);
    return .{ .name = "bun", .version = release.version };
}

pub fn installPackageManager(
    allocator: std.mem.Allocator,
    package_spec: types.PackageManagerSpec,
    skip_cache: bool,
) !bool {
    const install_path = try paths.getInstallPath(allocator, package_spec);
    const temp_dir = try createTempDir(allocator);
    defer cleanupTempDir(allocator, temp_dir);

    const installed_binary = try std.fs.path.join(allocator, &.{ install_path, "bun" });
    if (!skip_cache) {
        if (std.fs.openFileAbsolute(installed_binary, .{}) catch null) |existing| {
            existing.close();
            return true;
        }
    }

    const archive_path = try std.fs.path.join(allocator, &.{ temp_dir, try std.fmt.allocPrint(allocator, "bun-v{s}.zip", .{package_spec.version}) });
    const extract_dir = try std.fs.path.join(allocator, &.{ temp_dir, "extract" });
    const target_name = try getBunReleaseTarget(allocator);
    const extracted_binary = try std.fs.path.join(allocator, &.{ extract_dir, try std.fmt.allocPrint(allocator, "bun-{s}/bun", .{target_name}) });

    logging.friendly("Installing {s}@{s}", .{ package_spec.name, package_spec.version });

    try paths.removeTreeAbsoluteIfPresent(allocator, install_path);
    try paths.makePathAbsolute(allocator, extract_dir);
    try downloadFile(allocator, try getBunReleaseDownloadUrl(allocator, package_spec.version), archive_path);
    try extractZip(allocator, archive_path, extract_dir);
    try replaceInstalledBinary(allocator, extracted_binary, installed_binary);
    return false;
}

pub fn getExecutablePath(
    allocator: std.mem.Allocator,
    package_spec: types.PackageManagerSpec,
    executable_name: []const u8,
) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ try paths.getInstallPath(allocator, package_spec), executable_name });
}

fn fetchLatestBunRelease(allocator: std.mem.Allocator) !types.PackageManagerSpec {
    const asset_name = try getBunReleaseAssetName(allocator);
    const result = try http.fetchUrlToMemory(allocator, bun_latest_release_api, &github_api_headers);

    const parsed = try std.json.parseFromSlice(GitHubLatestRelease, allocator, result, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    for (parsed.value.assets) |asset| {
        if (std.mem.eql(u8, asset.name, asset_name)) {
            return .{
                .name = "bun",
                .version = try allocator.dupe(u8, normalizeBunReleaseVersion(parsed.value.tag_name)),
            };
        }
    }

    logging.userErrorFmt("Latest Bun release does not contain asset {s}", .{asset_name});
    return error.MissingReleaseAsset;
}

fn getBunReleaseTarget(allocator: std.mem.Allocator) ![]const u8 {
    const os_name: []const u8 = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => return error.UnsupportedTarget,
    };

    var arch_name: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x64",
        else => return error.UnsupportedTarget,
    };

    if (builtin.os.tag == .macos and builtin.cpu.arch == .x86_64 and try isRosettaTranslated(allocator)) {
        logging.info("Your shell is running in Rosetta 2. Downloading bun for darwin-aarch64 instead", .{});
        arch_name = "aarch64";
    }

    var target = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ os_name, arch_name });

    if (builtin.os.tag == .linux and try isAlpineLinux()) {
        target = try std.fmt.allocPrint(allocator, "{s}-musl", .{target});
    }

    if ((std.mem.startsWith(u8, target, "darwin-x64") or std.mem.startsWith(u8, target, "linux-x64")) and !hostHasAvx2()) {
        target = try std.fmt.allocPrint(allocator, "{s}-baseline", .{target});
    }

    return target;
}

fn getBunReleaseAssetName(allocator: std.mem.Allocator) ![]const u8 {
    const target = try getBunReleaseTarget(allocator);
    return try std.fmt.allocPrint(allocator, "bun-{s}.zip", .{target});
}

fn getBunReleaseDownloadUrl(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    const target = try getBunReleaseTarget(allocator);
    return try std.fmt.allocPrint(allocator, "{s}/releases/download/bun-v{s}/bun-{s}.zip", .{ bun_download_repo, version, target });
}

fn normalizeBunReleaseVersion(raw_version: []const u8) []const u8 {
    if (std.mem.startsWith(u8, raw_version, "bun-v")) return raw_version[5..];
    if (std.mem.startsWith(u8, raw_version, "bun-")) return raw_version[4..];
    return normalizeReleaseVersion(raw_version);
}

fn isRosettaTranslated(allocator: std.mem.Allocator) !bool {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sysctl", "-n", "sysctl.proc_translated" },
        .max_output_bytes = 32,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), "1");
}

fn isAlpineLinux() !bool {
    std.fs.accessAbsolute("/etc/alpine-release", .{}) catch return false;
    return true;
}

fn hostHasAvx2() bool {
    if (builtin.cpu.arch != .x86_64) return false;

    if (builtin.os.tag == .linux) {
        const file = std.fs.openFileAbsolute("/proc/cpuinfo", .{}) catch return false;
        defer file.close();

        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = file.read(&buffer) catch return false;
            if (bytes_read == 0) break;
            if (std.mem.indexOf(u8, buffer[0..bytes_read], "avx2") != null) return true;
        }
        return false;
    }

    return std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
}

fn createTempDir(allocator: std.mem.Allocator) ![]const u8 {
    const base_dir = std.process.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");

    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "pmm3-{x}", .{std.crypto.random.int(u64)});
        const path = try std.fs.path.join(allocator, &.{ base_dir, candidate });
        std.fs.cwd().makeDir(path) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return path;
    }

    return error.TemporaryNameUnavailable;
}

fn cleanupTempDir(allocator: std.mem.Allocator, temp_dir: []const u8) void {
    paths.removeTreeAbsoluteIfPresent(allocator, temp_dir) catch {};
}

fn downloadFile(allocator: std.mem.Allocator, url: []const u8, output_path: []const u8) !void {
    try http.fetchUrlToFile(allocator, url, &default_request_headers, output_path);
}

fn replaceInstalledBinary(allocator: std.mem.Allocator, source_path: []const u8, installed_path: []const u8) !void {
    const bin_dir = std.fs.path.dirname(installed_path) orelse return error.InvalidPath;
    const staged_path = try std.fs.path.join(allocator, &.{ bin_dir, "bun.new" });

    try paths.makePathAbsolute(allocator, bin_dir);
    try copyExecutable(source_path, staged_path);
    std.fs.renameAbsolute(staged_path, installed_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try std.fs.deleteFileAbsolute(installed_path);
            try std.fs.renameAbsolute(staged_path, installed_path);
        },
        else => return err,
    };
}

fn copyExecutable(source_path: []const u8, target_path: []const u8) !void {
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

fn extractZip(allocator: std.mem.Allocator, archive_path: []const u8, output_dir: []const u8) !void {
    var child = std.process.Child.init(&.{ "unzip", "-oqd", output_dir, archive_path }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch |err| switch (err) {
        error.FileNotFound => {
            logging.userError("unzip is required to install bun");
            return error.CommandFailed;
        },
        else => return err,
    };

    if (!process_utils.termSucceeded(term)) process_utils.exitForTerm(term);
}

fn normalizeReleaseVersion(raw_version: []const u8) []const u8 {
    if (raw_version.len > 0 and (raw_version[0] == 'v' or raw_version[0] == 'V')) {
        return raw_version[1..];
    }

    return raw_version;
}

test "requires matching project spec for package manager commands" {
    try std.testing.expect(requiresMatchingProjectSpec(&.{ "bun", "install" }));
    try std.testing.expect(requiresMatchingProjectSpec(&.{ "bun", "publish" }));
    try std.testing.expect(!requiresMatchingProjectSpec(&.{ "bun", "run", "dev" }));
    try std.testing.expect(!requiresMatchingProjectSpec(&.{ "bun", "x", "tsc" }));
    try std.testing.expect(!requiresMatchingProjectSpec(&.{"bun"}));
}
