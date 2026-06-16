const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const logging = @import("logging.zig");
const bun = @import("bun.zig");
const http = @import("http.zig");
const package_json = @import("package_json.zig");
const paths = @import("paths.zig");
const process_utils = @import("process_utils.zig");
const setup = @import("setup.zig");
const spec = @import("spec.zig");
const types = @import("types.zig");

const github_releases_api = "https://api.github.com/repos/ehyland/pmm3/releases?per_page=100";

const GitHubReleaseAsset = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

const GitHubRelease = struct {
    tag_name: []const u8,
    draft: bool = false,
    assets: []const GitHubReleaseAsset,
};

const RegistryManifest = struct {
    version: []const u8,
};

const PmmRelease = struct {
    version: []const u8,
    asset_name: []const u8,
    download_url: []const u8,
};

const PackageSource = struct {
    registry_package_name: []const u8,
    tarball_package_name: []const u8,
};

const RequestHeaders = []const std.http.Header;

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();

    const ctx = types.Ctx{
        .allocator = arena_state.allocator(),
        .io = init.io,
        .environ = init.minimal.environ,
    };

    const argv = try init.minimal.args.toSlice(ctx.allocator);
    if (argv.len == 0) return;

    const executable_name = std.fs.path.basename(argv[0]);

    if (spec.getShim(executable_name)) |shim| {
        if (std.mem.eql(u8, executable_name, "pmm3")) {
            try runPmmCli(ctx, argv);
            return;
        }

        try runPackageManager(ctx, shim, argv);
        return;
    }

    try runPmmCli(ctx, argv);
}

fn runPmmCli(ctx: types.Ctx, argv: []const []const u8) !void {
    if (argv.len < 2) {
        logging.printUsage();
        return;
    }

    const command = argv[1];

    if (std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "--version")) {
        std.debug.print("{s}\n", .{build_options.pmm_version});
        return;
    }

    if (std.mem.eql(u8, command, "update-local")) {
        try commandUpdateLocal(ctx);
        return;
    }

    if (std.mem.eql(u8, command, "update-default")) {
        const name = if (argv.len >= 3) argv[2] else "all";
        const version = if (argv.len >= 4) argv[3] else null;
        try commandUpdateDefault(ctx, name, version);
        return;
    }

    if (std.mem.eql(u8, command, "update-self")) {
        try commandUpdateSelf(ctx);
        return;
    }

    if (std.mem.eql(u8, command, "setup")) {
        var custom_rc: ?[]const u8 = null;
        var i: usize = 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--shell-rc-file")) {
                if (i + 1 < argv.len) {
                    custom_rc = argv[i + 1];
                    i += 1;
                } else {
                    logging.userError("--shell-rc-file requires a path");
                    std.process.exit(1);
                }
            }
        }
        try setup.run(ctx, custom_rc);
        return;
    }

    if (std.mem.eql(u8, command, "pin")) {
        if (argv.len < 4) {
            logging.userError("Usage: pmm3 pin <package-manager> <path-to-package>");
            std.process.exit(1);
        }

        try commandPin(ctx, argv[2], argv[3]);
        return;
    }

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        logging.printUsage();
        return;
    }

    logging.userError("Unknown command.");
    logging.printUsage();
    std.process.exit(1);
}

fn commandUpdateLocal(ctx: types.Ctx) !void {
    const found = (try package_json.findPackageManagerSpec(ctx)) orelse {
        logging.userError("Unable to find package.json with \"packageManager\" field");
        std.process.exit(1);
    };

    const latest = try getLatestVersion(ctx, found.spec.name);

    if (std.mem.eql(u8, latest.version, found.spec.version)) {
        logging.info("Already on latest version {s}@{s}", .{ latest.name, latest.version });
        return;
    }

    _ = try installPackageManager(ctx, latest, false);
    try package_json.writePackageManagerField(ctx, found.package_json_path, latest);

    logging.friendly("Updated registry!", .{});
    logging.info("  From: {s}@{s}", .{ found.spec.name, found.spec.version });
    logging.info("  To  : {s}@{s}", .{ latest.name, latest.version });
}

fn commandUpdateDefault(
    ctx: types.Ctx,
    name_arg: []const u8,
    version_arg: ?[]const u8,
) !void {
    if (std.mem.eql(u8, name_arg, "all")) {
        if (version_arg != null) {
            logging.userError("A version can only be provided when updating a single package manager.");
            std.process.exit(1);
        }

        logging.friendly("Updating all package managers", .{});

        inline for (spec.supported_package_managers) |name| {
            const package_spec = try getRequestedOrLatestVersion(ctx, name, null);
            _ = try installPackageManager(ctx, package_spec, false);
            try updateDefaultVersion(ctx, package_spec);
        }

        return;
    }

    if (!spec.isSupportedPackageManager(name_arg)) {
        logging.userErrorFmt("Sorry, \"{s}\" is not yet supported", .{name_arg});
        std.process.exit(1);
    }

    const package_spec = try getRequestedOrLatestVersion(ctx, name_arg, version_arg);
    _ = try installPackageManager(ctx, package_spec, false);
    try updateDefaultVersion(ctx, package_spec);
}

fn commandUpdateSelf(ctx: types.Ctx) !void {
    const latest = try fetchLatestPmmRelease(ctx);
    const current_version = normalizeReleaseVersion(build_options.pmm_version);

    if (spec.parseVersion(current_version)) |current| {
        const latest_version = try spec.parseVersion(latest.version);
        if (spec.compareVersions(current, latest_version) >= 0) {
            logging.info("pmm3 is already on the latest version {s}", .{latest.version});
            return;
        }
    } else |_| {
        logging.info("Current build version {s} is not a tagged release; upgrading pmm3 to {s}", .{ build_options.pmm_version, latest.version });
    }

    logging.friendly("Updating pmm3 to {s}", .{latest.version});

    const temp_dir = try createTempDir(ctx);
    defer cleanupTempDir(ctx, temp_dir);

    const archive_path = try std.fs.path.join(ctx.allocator, &.{ temp_dir, latest.asset_name });
    const extract_dir = try std.fs.path.join(ctx.allocator, &.{ temp_dir, "extract" });

    try paths.makePathAbsolute(ctx, extract_dir);
    try downloadFile(ctx, latest.download_url, archive_path);
    try extractTarball(ctx, archive_path, extract_dir, 0);

    const downloaded_binary = try findExtractedBinary(ctx, extract_dir);
    const installed_binary = try paths.getInstalledPmmPath(ctx);
    try replaceInstalledBinary(ctx, downloaded_binary, installed_binary);
    try runInstalledSetup(ctx, installed_binary);
}

fn commandPin(
    ctx: types.Ctx,
    package_manager_name: []const u8,
    input_path: []const u8,
) !void {
    if (!spec.isSupportedPackageManager(package_manager_name)) {
        logging.userErrorFmt("Sorry, \"{s}\" is not yet supported", .{package_manager_name});
        std.process.exit(1);
    }

    const cwd = try std.process.currentPathAlloc(ctx.io, ctx.allocator);
    const absolute_input_path = if (std.fs.path.isAbsolute(input_path))
        try ctx.allocator.dupe(u8, input_path)
    else
        try std.fs.path.join(ctx.allocator, &.{ cwd, input_path });
    const package_dir = if (std.mem.eql(u8, std.fs.path.basename(absolute_input_path), "package.json"))
        (std.fs.path.dirname(absolute_input_path) orelse absolute_input_path)
    else
        absolute_input_path;

    if (!try package_json.checkPackageExists(ctx, package_dir)) {
        const relative = try std.fs.path.relative(ctx.allocator, cwd, null, cwd, package_dir);
        logging.userErrorFmt("Sorry, \"package.json\" not found in ./{s}", .{relative});
        std.process.exit(1);
    }

    const latest = try getLatestVersion(ctx, package_manager_name);
    const package_json_path = try std.fs.path.join(ctx.allocator, &.{ package_dir, "package.json" });
    try package_json.writePackageManagerField(ctx, package_json_path, latest);

    logging.friendly("Pinned {s}@{s}", .{ latest.name, latest.version });
}

fn runPackageManager(
    ctx: types.Ctx,
    shim: types.Shim,
    argv: []const []const u8,
) !void {
    var found = try package_json.findPackageManagerSpec(ctx);

    if (found) |*configured| {
        if (!std.mem.eql(u8, configured.spec.name, shim.package_manager_name)) {
            if (paths.ignoreSpecMismatch(ctx)) {
                found = null;
            } else if (shim.allow_spec_mismatch) {
                found = null;
            } else if (spec.isNativePackageManager(shim.package_manager_name) and !bun.requiresMatchingProjectSpec(argv)) {
                found = null;
            } else {
                const cwd = try std.process.currentPathAlloc(ctx.io, ctx.allocator);
                const relative = try std.fs.path.relative(ctx.allocator, cwd, null, cwd, configured.package_json_path);
                logging.userErrorFmt("This project is configured to use {s}.", .{configured.spec.name});
                logging.info("See \"packageManager\" field in ./{s}", .{relative});
                std.process.exit(1);
            }
        }
    }

    const package_spec = if (found) |configured| configured.spec else try getDefaultSpec(ctx, shim.package_manager_name);

    _ = try installPackageManager(ctx, package_spec, false);
    const executable_path = try getExecutablePath(ctx, package_spec, shim.executable_name);

    const uses_node_runtime = !spec.isNativePackageManager(shim.package_manager_name);
    const child_argv = try ctx.allocator.alloc([]const u8, argv.len + @intFromBool(uses_node_runtime));

    if (uses_node_runtime) {
        child_argv[0] = "node";
        child_argv[1] = executable_path;
        var index: usize = 1;
        while (index < argv.len) : (index += 1) {
            child_argv[index + 1] = argv[index];
        }
    } else {
        child_argv[0] = executable_path;
        var index: usize = 1;
        while (index < argv.len) : (index += 1) {
            child_argv[index] = argv[index];
        }
    }

    var env_map = try std.process.Environ.createMap(ctx.environ, ctx.allocator);
    try env_map.put("PMM_IGNORE_SPEC_MISS_MATCH", "1");

    var child = try std.process.spawn(ctx.io, .{
        .argv = child_argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env_map,
    });
    const term = try child.wait(ctx.io);
    process_utils.exitForTerm(term);
}

fn getRequestedOrLatestVersion(
    ctx: types.Ctx,
    package_manager_name: []const u8,
    version: ?[]const u8,
) !types.PackageManagerSpec {
    if (version) |requested| {
        _ = try spec.parseVersion(requested);
        return .{ .name = package_manager_name, .version = requested };
    }

    return try getLatestVersion(ctx, package_manager_name);
}

fn getLatestVersion(ctx: types.Ctx, package_manager_name: []const u8) !types.PackageManagerSpec {
    if (spec.isNativePackageManager(package_manager_name)) {
        return try bun.getLatestVersion(ctx);
    }

    const registry = try paths.getRegistry(ctx);
    const package_source = try resolvePackageSource(package_manager_name, null);
    const manifest_package_name = try encodePackageNameForRegistryPath(ctx.allocator, package_source.registry_package_name);
    const manifest_url = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}/latest", .{ registry, manifest_package_name });
    const result = try http.fetchUrlToMemory(ctx, manifest_url, &default_request_headers);

    const manifest = try std.json.parseFromSliceLeaky(RegistryManifest, ctx.allocator, result, .{
        .ignore_unknown_fields = true,
    });

    const version = std.mem.trim(u8, manifest.version, " \t\r\n");
    _ = try spec.parseVersion(version);
    return .{ .name = package_manager_name, .version = version };
}

fn resolvePackageSource(package_manager_name: []const u8, version: ?[]const u8) !PackageSource {
    if (!std.mem.eql(u8, package_manager_name, "yarn")) {
        return .{
            .registry_package_name = package_manager_name,
            .tarball_package_name = package_manager_name,
        };
    }

    const uses_cli_dist = if (version) |resolved_version| blk: {
        const parsed = try spec.parseVersion(resolved_version);
        break :blk parsed.major >= 2;
    } else true;

    if (uses_cli_dist) {
        return .{
            .registry_package_name = "@yarnpkg/cli-dist",
            .tarball_package_name = "cli-dist",
        };
    }

    return .{
        .registry_package_name = "yarn",
        .tarball_package_name = "yarn",
    };
}

fn encodePackageNameForRegistryPath(allocator: std.mem.Allocator, package_name: []const u8) ![]const u8 {
    const slash_count = std.mem.count(u8, package_name, "/");
    if (slash_count != 0) {
        const extra_bytes = slash_count * 2;
        const encoded = try allocator.alloc(u8, package_name.len + extra_bytes);

        var write_index: usize = 0;
        for (package_name) |char| {
            if (char == '/') {
                @memcpy(encoded[write_index .. write_index + 3], "%2F");
                write_index += 3;
            } else {
                encoded[write_index] = char;
                write_index += 1;
            }
        }

        return encoded;
    }

    return package_name;
}

fn getDefaultSpec(ctx: types.Ctx, package_manager_name: []const u8) !types.PackageManagerSpec {
    const version = try getDefaultVersion(ctx, package_manager_name);
    return .{ .name = package_manager_name, .version = version };
}

fn getDefaultVersion(ctx: types.Ctx, package_manager_name: []const u8) ![]const u8 {
    const default_path = try paths.getDefaultFilePath(ctx, package_manager_name);
    if (try paths.readFileIfPresent(ctx, default_path)) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len != 0) {
            if (spec.parseVersion(trimmed)) |_| {
                return trimmed;
            } else |_| {}
        }
    }

    const latest = try getLatestVersion(ctx, package_manager_name);
    try updateDefaultVersion(ctx, latest);
    return latest.version;
}

fn updateDefaultVersion(ctx: types.Ctx, package_spec: types.PackageManagerSpec) !void {
    const default_path = try paths.getDefaultFilePath(ctx, package_spec.name);
    const default_dir = std.fs.path.dirname(default_path) orelse return error.InvalidPath;
    try paths.makePathAbsolute(ctx, default_dir);
    logging.friendly("Setting {s} default to version {s}", .{ package_spec.name, package_spec.version });

    const file = try std.Io.Dir.createFileAbsolute(ctx.io, default_path, .{ .truncate = true });
    defer file.close(ctx.io);
    try file.writeStreamingAll(ctx.io, package_spec.version);
}

fn fetchLatestPmmRelease(ctx: types.Ctx) !PmmRelease {
    const asset_name = try getCurrentReleaseAssetName(ctx.allocator);
    const result = try http.fetchUrlToMemory(ctx, github_releases_api, &github_api_headers);

    const parsed = try std.json.parseFromSlice([]GitHubRelease, ctx.allocator, result, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    return selectLatestRelease(ctx.allocator, parsed.value, asset_name);
}

fn selectLatestRelease(
    allocator: std.mem.Allocator,
    releases: []const GitHubRelease,
    asset_name: []const u8,
) !PmmRelease {
    var best_release: ?struct {
        version: spec.Version,
        release: GitHubRelease,
        asset: GitHubReleaseAsset,
    } = null;

    for (releases) |release| {
        if (release.draft) continue;

        const normalized_version = normalizeReleaseVersion(release.tag_name);
        const parsed_version = spec.parseVersion(normalized_version) catch continue;
        const asset = findReleaseAsset(release.assets, asset_name) orelse continue;

        if (best_release == null or spec.compareVersions(parsed_version, best_release.?.version) > 0) {
            best_release = .{
                .version = parsed_version,
                .release = release,
                .asset = asset,
            };
        }
    }

    if (best_release) |selected| {
        return .{
            .version = try allocator.dupe(u8, normalizeReleaseVersion(selected.release.tag_name)),
            .asset_name = try allocator.dupe(u8, selected.asset.name),
            .download_url = try allocator.dupe(u8, selected.asset.browser_download_url),
        };
    }

    logging.userErrorFmt("Unable to find a published release with asset {s}", .{asset_name});
    return error.MissingReleaseAsset;
}

fn findReleaseAsset(assets: []const GitHubReleaseAsset, expected_name: []const u8) ?GitHubReleaseAsset {
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.name, expected_name)) return asset;
    }

    return null;
}

fn getCurrentReleaseAssetName(allocator: std.mem.Allocator) ![]const u8 {
    const os_name = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => return error.UnsupportedTarget,
    };

    const arch_name = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => return error.UnsupportedTarget,
    };

    return try std.fmt.allocPrint(allocator, "pmm3-{s}-{s}.tar.gz", .{ os_name, arch_name });
}

fn normalizeReleaseVersion(raw_version: []const u8) []const u8 {
    if (raw_version.len > 0 and (raw_version[0] == 'v' or raw_version[0] == 'V')) {
        return raw_version[1..];
    }

    return raw_version;
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

fn extractTarball(ctx: types.Ctx, archive_path: []const u8, output_dir: []const u8, strip_components: u32) !void {
    const archive = try std.Io.Dir.openFileAbsolute(ctx.io, archive_path, .{});
    defer archive.close(ctx.io);

    var archive_buffer: [4096]u8 = undefined;
    var archive_reader = archive.reader(ctx.io, &archive_buffer);
    var gzip_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&archive_reader.interface, .gzip, &gzip_buffer);
    var output_dir_handle = try std.Io.Dir.openDirAbsolute(ctx.io, output_dir, .{});
    defer output_dir_handle.close(ctx.io);

    try std.tar.extract(ctx.io, output_dir_handle, &decompressor.reader, .{
        .strip_components = strip_components,
    });
}

fn findExtractedBinary(ctx: types.Ctx, extract_dir: []const u8) ![]const u8 {
    const direct_path = try std.fs.path.join(ctx.allocator, &.{ extract_dir, "pmm3" });
    const direct_file = std.Io.Dir.openFileAbsolute(ctx.io, direct_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (direct_file) |file| {
        file.close(ctx.io);
        return direct_path;
    }
    ctx.allocator.free(direct_path);

    var extract_handle = try std.Io.Dir.openDirAbsolute(ctx.io, extract_dir, .{ .iterate = true });
    defer extract_handle.close(ctx.io);

    var walker = try extract_handle.walk(ctx.allocator);
    defer walker.deinit();

    while (try walker.next(ctx.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "pmm3")) continue;
        return try std.fs.path.join(ctx.allocator, &.{ extract_dir, entry.path });
    }

    return error.FileNotFound;
}

fn replaceInstalledBinary(ctx: types.Ctx, source_path: []const u8, installed_path: []const u8) !void {
    const bin_dir = std.fs.path.dirname(installed_path) orelse return error.InvalidPath;
    const staged_path = try std.fs.path.join(ctx.allocator, &.{ bin_dir, "pmm3.new" });

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

fn runInstalledSetup(ctx: types.Ctx, installed_binary: []const u8) !void {
    logging.info("Running setup with {s}", .{installed_binary});

    var child = try std.process.spawn(ctx.io, .{
        .argv = &.{ installed_binary, "setup" },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try child.wait(ctx.io);
    if (!process_utils.termSucceeded(term)) process_utils.exitForTerm(term);
}

test "normalize release version trims leading v" {
    try std.testing.expectEqualStrings("1.2.3", normalizeReleaseVersion("v1.2.3"));
    try std.testing.expectEqualStrings("1.2.3", normalizeReleaseVersion("1.2.3"));
}

test "compare versions orders semver values" {
    try std.testing.expect(spec.compareVersions(try spec.parseVersion("1.2.3"), try spec.parseVersion("1.2.4")) < 0);
    try std.testing.expect(spec.compareVersions(try spec.parseVersion("2.0.0"), try spec.parseVersion("1.9.9")) > 0);
    try std.testing.expectEqual(@as(i8, 0), spec.compareVersions(try spec.parseVersion("3.4.5"), try spec.parseVersion("3.4.5")));
}

test "fetchLatestPmmRelease selection prefers highest semver release" {
    const as = std.testing.allocator;
    const asset_name = "pmm3-linux-x64.tar.gz";
    const releases = [_]GitHubRelease{
        .{
            .tag_name = "v1.2.3",
            .assets = &.{.{
                .name = asset_name,
                .browser_download_url = "https://example.com/v1.2.3.tar.gz",
            }},
        },
        .{
            .tag_name = "v1.2.4-alpha.2",
            .assets = &.{.{
                .name = asset_name,
                .browser_download_url = "https://example.com/v1.2.4-alpha.2.tar.gz",
            }},
        },
        .{
            .tag_name = "v1.2.4-alpha.1",
            .assets = &.{.{
                .name = asset_name,
                .browser_download_url = "https://example.com/v1.2.4-alpha.1.tar.gz",
            }},
        },
    };

    const selected = try selectLatestRelease(as, &releases, asset_name);
    defer {
        as.free(selected.version);
        as.free(selected.asset_name);
        as.free(selected.download_url);
    }

    try std.testing.expectEqualStrings("1.2.4-alpha.2", selected.version);
    try std.testing.expectEqualStrings("https://example.com/v1.2.4-alpha.2.tar.gz", selected.download_url);
}

test "fetchLatestPmmRelease selection prefers stable over same core prerelease" {
    const as = std.testing.allocator;
    const asset_name = "pmm3-linux-x64.tar.gz";
    const releases = [_]GitHubRelease{
        .{
            .tag_name = "v1.2.4-alpha.3",
            .assets = &.{.{
                .name = asset_name,
                .browser_download_url = "https://example.com/v1.2.4-alpha.3.tar.gz",
            }},
        },
        .{
            .tag_name = "v1.2.4",
            .assets = &.{.{
                .name = asset_name,
                .browser_download_url = "https://example.com/v1.2.4.tar.gz",
            }},
        },
    };

    const selected = try selectLatestRelease(as, &releases, asset_name);
    defer {
        as.free(selected.version);
        as.free(selected.asset_name);
        as.free(selected.download_url);
    }

    try std.testing.expectEqualStrings("1.2.4", selected.version);
}

test "fetchLatestPmmRelease selection skips drafts and missing assets" {
    const as = std.testing.allocator;
    const asset_name = "pmm3-linux-x64.tar.gz";
    const releases = [_]GitHubRelease{
        .{
            .tag_name = "v9.9.9-alpha.1",
            .draft = true,
            .assets = &.{.{
                .name = asset_name,
                .browser_download_url = "https://example.com/draft.tar.gz",
            }},
        },
        .{
            .tag_name = "v1.2.4-alpha.1",
            .assets = &.{.{
                .name = "pmm3-darwin-x64.tar.gz",
                .browser_download_url = "https://example.com/darwin.tar.gz",
            }},
        },
        .{
            .tag_name = "v1.2.3",
            .assets = &.{.{
                .name = asset_name,
                .browser_download_url = "https://example.com/v1.2.3.tar.gz",
            }},
        },
    };

    const selected = try selectLatestRelease(as, &releases, asset_name);
    defer {
        as.free(selected.version);
        as.free(selected.asset_name);
        as.free(selected.download_url);
    }

    try std.testing.expectEqualStrings("1.2.3", selected.version);
}

fn installPackageManager(
    ctx: types.Ctx,
    package_spec: types.PackageManagerSpec,
    skip_cache: bool,
) !bool {
    if (spec.isNativePackageManager(package_spec.name)) {
        return bun.installPackageManager(ctx, package_spec, skip_cache);
    }

    const install_path = try paths.getInstallPath(ctx, package_spec);
    const temp_dir = try createTempDir(ctx);
    defer cleanupTempDir(ctx, temp_dir);

    const package_json_path = try paths.getInstallPackageJsonPath(ctx, package_spec);

    if (!skip_cache and (try paths.readFileIfPresent(ctx, package_json_path)) != null) {
        return true;
    }

    const resolved_version = try spec.getVersionCore(package_spec.version);
    const package_source = try resolvePackageSource(package_spec.name, package_spec.version);
    const tarball_url = try std.fmt.allocPrint(
        ctx.allocator,
        "{s}/{s}/-/{s}-{s}.tgz",
        .{
            try paths.getRegistry(ctx),
            package_source.registry_package_name,
            package_source.tarball_package_name,
            resolved_version,
        },
    );
    const archive_path = try std.fs.path.join(ctx.allocator, &.{ temp_dir, "package.tgz" });

    logging.friendly("Installing {s}@{s}", .{ package_spec.name, package_spec.version });

    paths.removeTreeAbsoluteIfPresent(ctx, install_path);
    try paths.makePathAbsolute(ctx, install_path);
    try downloadFile(ctx, tarball_url, archive_path);
    try extractTarball(ctx, archive_path, install_path, 1);

    if ((try paths.readFileIfPresent(ctx, package_json_path)) == null) {
        return error.CommandFailed;
    }

    return false;
}

const default_request_headers = [_]std.http.Header{
    .{ .name = "User-Agent", .value = "pmm3" },
};

const github_api_headers = [_]std.http.Header{
    .{ .name = "Accept", .value = "application/vnd.github+json" },
    .{ .name = "User-Agent", .value = "pmm3" },
};

test "resolvePackageSource uses cli-dist for latest yarn lookup" {
    const source = try resolvePackageSource("yarn", null);
    try std.testing.expectEqualStrings("@yarnpkg/cli-dist", source.registry_package_name);
    try std.testing.expectEqualStrings("cli-dist", source.tarball_package_name);
}

test "resolvePackageSource keeps legacy yarn for v1" {
    const source = try resolvePackageSource("yarn", "1.22.22");
    try std.testing.expectEqualStrings("yarn", source.registry_package_name);
    try std.testing.expectEqualStrings("yarn", source.tarball_package_name);
}

test "resolvePackageSource uses cli-dist for yarn 2 plus" {
    const source = try resolvePackageSource("yarn", "4.1.0");
    try std.testing.expectEqualStrings("@yarnpkg/cli-dist", source.registry_package_name);
    try std.testing.expectEqualStrings("cli-dist", source.tarball_package_name);
}

test "resolvePackageSource uses cli-dist for yarn 2 plus with sha suffix" {
    const source = try resolvePackageSource("yarn", "3.2.3+sha224.953c8233f7a92884eee2de69a1b92d1f2ec1655e66d08071ba9a02fa");
    try std.testing.expectEqualStrings("@yarnpkg/cli-dist", source.registry_package_name);
    try std.testing.expectEqualStrings("cli-dist", source.tarball_package_name);
}

test "encodePackageNameForRegistryPath escapes scoped packages" {
    const as = std.testing.allocator;
    const encoded = try encodePackageNameForRegistryPath(as, "@yarnpkg/cli-dist");
    defer if (!std.mem.eql(u8, encoded, "@yarnpkg/cli-dist")) as.free(encoded);

    try std.testing.expectEqualStrings("@yarnpkg%2Fcli-dist", encoded);
}

test "findExtractedBinary walks nested directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "nested/bin");
    const file = try tmp.dir.createFile(std.testing.io, "nested/bin/pmm3", .{});
    file.close(std.testing.io);

    const as = std.testing.allocator;
    const absolute_tmp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", as);
    defer as.free(absolute_tmp);

    const test_ctx = types.Ctx{
        .allocator = as,
        .io = std.testing.io,
        .environ = undefined,
    };

    const found = try findExtractedBinary(test_ctx, absolute_tmp);
    defer as.free(found);

    const expected = try std.fs.path.join(as, &.{ absolute_tmp, "nested/bin/pmm3" });
    defer as.free(expected);

    try std.testing.expectEqualStrings(expected, found);
}

fn getExecutablePath(
    ctx: types.Ctx,
    package_spec: types.PackageManagerSpec,
    executable_name: []const u8,
) ![]const u8 {
    if (spec.isNativePackageManager(package_spec.name)) {
        return try bun.getExecutablePath(ctx, package_spec, executable_name);
    }

    const package_json_path = try paths.getInstallPackageJsonPath(ctx, package_spec);
    const relative_path = (try package_json.readPackageExecutablePath(ctx, package_json_path, executable_name)) orelse {
        return error.CommandFailed;
    };
    const install_path = try paths.getInstallPath(ctx, package_spec);
    return try std.fs.path.join(ctx.allocator, &.{ install_path, relative_path });
}
