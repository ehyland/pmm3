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

pub fn getLatestVersion(ctx: types.Ctx) !types.PackageManagerSpec {
    const release = try fetchLatestBunRelease(ctx);
    return .{ .name = "bun", .version = release.version };
}

pub fn installPackageManager(
    ctx: types.Ctx,
    package_spec: types.PackageManagerSpec,
    skip_cache: bool,
) !bool {
    const install_path = try paths.getInstallPath(ctx, package_spec);
    const temp_dir = try createTempDir(ctx);
    defer cleanupTempDir(ctx, temp_dir);

    const installed_binary = try std.fs.path.join(ctx.allocator, &.{ install_path, "bun" });
    if (!skip_cache) {
        if (std.Io.Dir.openFileAbsolute(ctx.io, installed_binary, .{}) catch null) |existing| {
            existing.close(ctx.io);
            return true;
        }
    }

    const archive_path = try std.fs.path.join(ctx.allocator, &.{ temp_dir, try std.fmt.allocPrint(ctx.allocator, "bun-v{s}.zip", .{package_spec.version}) });
    const extract_dir = try std.fs.path.join(ctx.allocator, &.{ temp_dir, "extract" });
    const target_name = try getBunReleaseTarget(ctx);
    const extracted_binary = try std.fs.path.join(ctx.allocator, &.{ extract_dir, try std.fmt.allocPrint(ctx.allocator, "bun-{s}/bun", .{target_name}) });

    logging.friendly("Installing {s}@{s}", .{ package_spec.name, package_spec.version });

    paths.removeTreeAbsoluteIfPresent(ctx, install_path);
    try paths.makePathAbsolute(ctx, extract_dir);
    try downloadFile(ctx, try getBunReleaseDownloadUrl(ctx, package_spec.version), archive_path);
    try extractZip(ctx, archive_path, extract_dir);
    try replaceInstalledBinary(ctx, extracted_binary, installed_binary);
    return false;
}

pub fn getExecutablePath(
    ctx: types.Ctx,
    package_spec: types.PackageManagerSpec,
    executable_name: []const u8,
) ![]const u8 {
    return try std.fs.path.join(ctx.allocator, &.{ try paths.getInstallPath(ctx, package_spec), executable_name });
}

fn fetchLatestBunRelease(ctx: types.Ctx) !types.PackageManagerSpec {
    const asset_name = try getBunReleaseAssetName(ctx);
    const result = try http.fetchUrlToMemory(ctx, bun_latest_release_api, &github_api_headers);

    const parsed = try std.json.parseFromSlice(GitHubLatestRelease, ctx.allocator, result, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    for (parsed.value.assets) |asset| {
        if (std.mem.eql(u8, asset.name, asset_name)) {
            return .{
                .name = "bun",
                .version = try ctx.allocator.dupe(u8, normalizeBunReleaseVersion(parsed.value.tag_name)),
            };
        }
    }

    logging.userErrorFmt("Latest Bun release does not contain asset {s}", .{asset_name});
    return error.MissingReleaseAsset;
}

fn getBunReleaseTarget(ctx: types.Ctx) ![]const u8 {
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

    if (builtin.os.tag == .macos and builtin.cpu.arch == .x86_64 and try isRosettaTranslated(ctx)) {
        logging.info("Your shell is running in Rosetta 2. Downloading bun for darwin-aarch64 instead", .{});
        arch_name = "aarch64";
    }

    var target = try std.fmt.allocPrint(ctx.allocator, "{s}-{s}", .{ os_name, arch_name });

    if (builtin.os.tag == .linux and try isAlpineLinux(ctx.io)) {
        target = try std.fmt.allocPrint(ctx.allocator, "{s}-musl", .{target});
    }

    if ((std.mem.startsWith(u8, target, "darwin-x64") or std.mem.startsWith(u8, target, "linux-x64")) and !hostHasAvx2(ctx.io)) {
        target = try std.fmt.allocPrint(ctx.allocator, "{s}-baseline", .{target});
    }

    return target;
}

fn getBunReleaseAssetName(ctx: types.Ctx) ![]const u8 {
    const target = try getBunReleaseTarget(ctx);
    return try std.fmt.allocPrint(ctx.allocator, "bun-{s}.zip", .{target});
}

fn getBunReleaseDownloadUrl(ctx: types.Ctx, version: []const u8) ![]const u8 {
    const target = try getBunReleaseTarget(ctx);
    return try std.fmt.allocPrint(ctx.allocator, "{s}/releases/download/bun-v{s}/bun-{s}.zip", .{ bun_download_repo, version, target });
}

fn normalizeBunReleaseVersion(raw_version: []const u8) []const u8 {
    if (std.mem.startsWith(u8, raw_version, "bun-v")) return raw_version[5..];
    if (std.mem.startsWith(u8, raw_version, "bun-")) return raw_version[4..];
    return normalizeReleaseVersion(raw_version);
}

fn isRosettaTranslated(ctx: types.Ctx) !bool {
    const result = try std.process.run(ctx.allocator, ctx.io, .{
        .argv = &.{ "sysctl", "-n", "sysctl.proc_translated" },
        .stdout_limit = .limited(32),
    });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);

    return std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), "1");
}

fn isAlpineLinux(io: std.Io) !bool {
    std.Io.Dir.accessAbsolute(io, "/etc/alpine-release", .{}) catch return false;
    return true;
}

fn hostHasAvx2(io: std.Io) bool {
    if (builtin.cpu.arch != .x86_64) return false;

    if (builtin.os.tag == .linux) {
        const file = std.Io.Dir.openFileAbsolute(io, "/proc/cpuinfo", .{}) catch return false;
        defer file.close(io);

        var file_reader = file.reader(io, &.{});
        var buf: [4096]u8 = undefined;
        while (true) {
            const bytes_read = file_reader.interface.readSliceShort(&buf) catch return false;
            if (bytes_read == 0) break;
            if (std.mem.find(u8, buf[0..bytes_read], "avx2") != null) return true;
        }
        return false;
    }

    return std.Target.x86.featureSetHas(builtin.cpu.features, .avx2);
}

fn createTempDir(ctx: types.Ctx) ![]const u8 {
    const base_dir = ctx.environ.getAlloc(ctx.allocator, "TMPDIR") catch try ctx.allocator.dupe(u8, "/tmp");

    var attempt: usize = 0;
    while (attempt < 32) : (attempt += 1) {
        var random_bytes: [@sizeOf(u64)]u8 = undefined;
        ctx.io.random(&random_bytes);
        const rand_val: u64 = @bitCast(random_bytes);
        const candidate = try std.fmt.allocPrint(ctx.allocator, "pmm3-{x}", .{rand_val});
        const path = try std.fs.path.join(ctx.allocator, &.{ base_dir, candidate });
        std.Io.Dir.cwd().createDir(ctx.io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return path;
    }

    return error.TemporaryNameUnavailable;
}

fn cleanupTempDir(ctx: types.Ctx, temp_dir: []const u8) void {
    paths.removeTreeAbsoluteIfPresent(ctx, temp_dir);
}

fn downloadFile(ctx: types.Ctx, url: []const u8, output_path: []const u8) !void {
    try http.fetchUrlToFile(ctx, url, &default_request_headers, output_path);
}

fn replaceInstalledBinary(ctx: types.Ctx, source_path: []const u8, installed_path: []const u8) !void {
    const bin_dir = std.fs.path.dirname(installed_path) orelse return error.InvalidPath;
    const staged_path = try std.fs.path.join(ctx.allocator, &.{ bin_dir, "bun.new" });

    try paths.makePathAbsolute(ctx, bin_dir);
    try copyExecutable(ctx, source_path, staged_path);
    std.Io.Dir.renameAbsolute(staged_path, installed_path, ctx.io) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.deleteFileAbsolute(ctx.io, installed_path);
            try std.Io.Dir.renameAbsolute(staged_path, installed_path, ctx.io);
        },
        else => return err,
    };
}

fn copyExecutable(ctx: types.Ctx, source_path: []const u8, target_path: []const u8) !void {
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

fn extractZip(ctx: types.Ctx, archive_path: []const u8, output_dir: []const u8) !void {
    var child = std.process.spawn(ctx.io, .{
        .argv = &.{ "unzip", "-oqd", output_dir, archive_path },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            logging.userError("unzip is required to install bun");
            return error.CommandFailed;
        },
        else => return err,
    };

    const term = try child.wait(ctx.io);
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
