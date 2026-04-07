const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const logging = @import("logging.zig");
const bun = @import("bun.zig");
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

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const argv = try std.process.argsAlloc(allocator);
    if (argv.len == 0) return;

    // The same binary is invoked both as `pmm3` and via shim names like `pnpm`.
    const executable_name = std.fs.path.basename(argv[0]);

    if (spec.getShim(executable_name)) |shim| {
        if (std.mem.eql(u8, executable_name, "pmm3")) {
            try runPmmCli(allocator, argv);
            return;
        }

        try runPackageManager(allocator, shim, argv);
        return;
    }

    try runPmmCli(allocator, argv);
}

fn runPmmCli(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    if (argv.len < 2) {
        logging.printUsage();
        return;
    }

    const command = argv[1];

    if (std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "--version")) {
        std.debug.print("{s}\n", .{build_options.pmm_version});
        return;
    }

    // Keep command parsing explicit so the supported surface stays obvious.

    if (std.mem.eql(u8, command, "update-local")) {
        try commandUpdateLocal(allocator);
        return;
    }

    if (std.mem.eql(u8, command, "update-default")) {
        const name = if (argv.len >= 3) argv[2] else "all";
        const version = if (argv.len >= 4) argv[3] else null;
        try commandUpdateDefault(allocator, name, version);
        return;
    }

    if (std.mem.eql(u8, command, "update-self")) {
        try commandUpdateSelf(allocator);
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
        try setup.run(allocator, custom_rc);
        return;
    }

    if (std.mem.eql(u8, command, "pin")) {
        if (argv.len < 4) {
            logging.userError("Usage: pmm3 pin <package-manager> <path-to-package>");
            std.process.exit(1);
        }

        try commandPin(allocator, argv[2], argv[3]);
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

fn commandUpdateLocal(allocator: std.mem.Allocator) !void {
    const found = (try package_json.findPackageManagerSpec(allocator)) orelse {
        logging.userError("Unable to find package.json with \"packageManager\" field");
        std.process.exit(1);
    };

    const latest = try getLatestVersion(allocator, found.spec.name);

    if (std.mem.eql(u8, latest.version, found.spec.version)) {
        logging.info("Already on latest version {s}@{s}", .{ latest.name, latest.version });
        return;
    }

    _ = try installPackageManager(allocator, latest, false);
    try package_json.writePackageManagerField(allocator, found.package_json_path, latest);

    logging.friendly("Updated registry!", .{});
    logging.info("  From: {s}@{s}", .{ found.spec.name, found.spec.version });
    logging.info("  To  : {s}@{s}", .{ latest.name, latest.version });
}

fn commandUpdateDefault(
    allocator: std.mem.Allocator,
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
            const package_spec = try getRequestedOrLatestVersion(allocator, name, null);
            _ = try installPackageManager(allocator, package_spec, false);
            try updateDefaultVersion(allocator, package_spec);
        }

        return;
    }

    if (!spec.isSupportedPackageManager(name_arg)) {
        logging.userErrorFmt("Sorry, \"{s}\" is not yet supported", .{name_arg});
        std.process.exit(1);
    }

    const package_spec = try getRequestedOrLatestVersion(allocator, name_arg, version_arg);
    _ = try installPackageManager(allocator, package_spec, false);
    try updateDefaultVersion(allocator, package_spec);
}

fn commandUpdateSelf(allocator: std.mem.Allocator) !void {
    const latest = try fetchLatestPmmRelease(allocator);
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

    const temp_dir = try createTempDir(allocator);
    defer cleanupTempDir(allocator, temp_dir);

    const archive_path = try std.fs.path.join(allocator, &.{ temp_dir, latest.asset_name });
    const extract_dir = try std.fs.path.join(allocator, &.{ temp_dir, "extract" });

    try paths.makePathAbsolute(allocator, extract_dir);
    try downloadFile(allocator, latest.download_url, archive_path);
    try extractTarball(allocator, archive_path, extract_dir, 0);

    const downloaded_binary = try findExtractedBinary(allocator, extract_dir);
    const installed_binary = try paths.getInstalledPmmPath(allocator);
    try replaceInstalledBinary(allocator, downloaded_binary, installed_binary);
    try runInstalledSetup(allocator, installed_binary);
}

fn commandPin(
    allocator: std.mem.Allocator,
    package_manager_name: []const u8,
    input_path: []const u8,
) !void {
    if (!spec.isSupportedPackageManager(package_manager_name)) {
        logging.userErrorFmt("Sorry, \"{s}\" is not yet supported", .{package_manager_name});
        std.process.exit(1);
    }

    const cwd = try std.process.getCwdAlloc(allocator);
    const absolute_input_path = if (std.fs.path.isAbsolute(input_path))
        try allocator.dupe(u8, input_path)
    else
        try std.fs.path.join(allocator, &.{ cwd, input_path });
    const package_dir = if (std.mem.eql(u8, std.fs.path.basename(absolute_input_path), "package.json"))
        (std.fs.path.dirname(absolute_input_path) orelse absolute_input_path)
    else
        absolute_input_path;

    if (!try package_json.checkPackageExists(allocator, package_dir)) {
        const relative = try std.fs.path.relative(allocator, cwd, package_dir);
        logging.userErrorFmt("Sorry, \"package.json\" not found in ./{s}", .{relative});
        std.process.exit(1);
    }

    const latest = try getLatestVersion(allocator, package_manager_name);
    const package_json_path = try std.fs.path.join(allocator, &.{ package_dir, "package.json" });
    try package_json.writePackageManagerField(allocator, package_json_path, latest);

    logging.friendly("Pinned {s}@{s}", .{ latest.name, latest.version });
}

fn runPackageManager(
    allocator: std.mem.Allocator,
    shim: types.Shim,
    argv: []const []const u8,
) !void {
    var found = try package_json.findPackageManagerSpec(allocator);

    if (found) |*configured| {
        if (!std.mem.eql(u8, configured.spec.name, shim.package_manager_name)) {
            if (paths.ignoreSpecMismatch(allocator)) {
                found = null;
            } else if (spec.isNativePackageManager(shim.package_manager_name) and !bun.requiresMatchingProjectSpec(argv)) {
                found = null;
            } else {
                const cwd = try std.process.getCwdAlloc(allocator);
                const relative = try std.fs.path.relative(allocator, cwd, configured.package_json_path);
                logging.userErrorFmt("This project is configured to use {s}.", .{configured.spec.name});
                logging.info("See \"packageManager\" field in ./{s}", .{relative});
                std.process.exit(1);
            }
        }
    }

    // If no project-level spec exists, fall back to the cached global default.
    const package_spec = if (found) |configured| configured.spec else try getDefaultSpec(allocator, shim.package_manager_name);

    _ = try installPackageManager(allocator, package_spec, false);
    const executable_path = try getExecutablePath(allocator, package_spec, shim.executable_name);

    const uses_node_runtime = !spec.isNativePackageManager(shim.package_manager_name);
    const child_argv = try allocator.alloc([]const u8, argv.len + @intFromBool(uses_node_runtime));

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

    var env_map = try std.process.getEnvMap(allocator);
    try env_map.put("PMM_IGNORE_SPEC_MISS_MATCH", "1");

    var child = std.process.Child.init(child_argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.env_map = &env_map;

    const term = try child.spawnAndWait();
    process_utils.exitForTerm(term);
}

fn getRequestedOrLatestVersion(
    allocator: std.mem.Allocator,
    package_manager_name: []const u8,
    version: ?[]const u8,
) !types.PackageManagerSpec {
    if (version) |requested| {
        _ = try spec.parseVersion(requested);
        return .{ .name = package_manager_name, .version = requested };
    }

    return try getLatestVersion(allocator, package_manager_name);
}

fn getLatestVersion(allocator: std.mem.Allocator, package_manager_name: []const u8) !types.PackageManagerSpec {
    if (spec.isNativePackageManager(package_manager_name)) {
        return try bun.getLatestVersion(allocator);
    }

    const registry = try paths.getRegistry(allocator);
    const package_source = try resolvePackageSource(package_manager_name, null);
    const manifest_package_name = try encodePackageNameForRegistryPath(allocator, package_source.registry_package_name);
    const manifest_url = try std.fmt.allocPrint(allocator, "{s}/{s}/latest", .{ registry, manifest_package_name });
    const result = try fetchUrlToMemory(allocator, manifest_url, &default_request_headers);

    const manifest = try std.json.parseFromSliceLeaky(RegistryManifest, allocator, result, .{
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

fn getDefaultSpec(allocator: std.mem.Allocator, package_manager_name: []const u8) !types.PackageManagerSpec {
    const version = try getDefaultVersion(allocator, package_manager_name);
    return .{ .name = package_manager_name, .version = version };
}

fn getDefaultVersion(allocator: std.mem.Allocator, package_manager_name: []const u8) ![]const u8 {
    const default_path = try paths.getDefaultFilePath(allocator, package_manager_name);
    if (try paths.readFileIfPresent(allocator, default_path)) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len != 0) {
            if (spec.parseVersion(trimmed)) |_| {
                return trimmed;
            } else |_| {}
        }
    }

    const latest = try getLatestVersion(allocator, package_manager_name);
    try updateDefaultVersion(allocator, latest);
    return latest.version;
}

fn updateDefaultVersion(allocator: std.mem.Allocator, package_spec: types.PackageManagerSpec) !void {
    const default_path = try paths.getDefaultFilePath(allocator, package_spec.name);
    const default_dir = std.fs.path.dirname(default_path) orelse return error.InvalidPath;
    try paths.makePathAbsolute(allocator, default_dir);
    logging.friendly("Setting {s} default to version {s}", .{ package_spec.name, package_spec.version });

    const file = try std.fs.createFileAbsolute(default_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(package_spec.version);
}

fn fetchLatestPmmRelease(allocator: std.mem.Allocator) !PmmRelease {
    const asset_name = try getCurrentReleaseAssetName(allocator);
    const result = try fetchUrlToMemory(allocator, github_releases_api, &github_api_headers);

    const parsed = try std.json.parseFromSlice([]GitHubRelease, allocator, result, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    return selectLatestRelease(allocator, parsed.value, asset_name);
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
    try fetchUrlToFile(allocator, url, &default_request_headers, output_path);
}

fn extractTarball(_: std.mem.Allocator, archive_path: []const u8, output_dir: []const u8, strip_components: u32) !void {
    const archive = try std.fs.openFileAbsolute(archive_path, .{});
    defer archive.close();

    var archive_buffer: [4096]u8 = undefined;
    var archive_reader = archive.reader(&archive_buffer);
    var gzip_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&archive_reader.interface, .gzip, &gzip_buffer);
    var output_dir_handle = try std.fs.openDirAbsolute(output_dir, .{});
    defer output_dir_handle.close();

    try std.tar.pipeToFileSystem(output_dir_handle, &decompressor.reader, .{
        .strip_components = strip_components,
    });
}

fn findExtractedBinary(allocator: std.mem.Allocator, extract_dir: []const u8) ![]const u8 {
    const direct_path = try std.fs.path.join(allocator, &.{ extract_dir, "pmm3" });
    const direct_file = std.fs.openFileAbsolute(direct_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (direct_file) |file| {
        file.close();
        return direct_path;
    }
    allocator.free(direct_path);

    var extract_handle = try std.fs.openDirAbsolute(extract_dir, .{ .iterate = true });
    defer extract_handle.close();

    var walker = try extract_handle.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "pmm3")) continue;
        return try std.fs.path.join(allocator, &.{ extract_dir, entry.path });
    }

    return error.FileNotFound;
}

fn replaceInstalledBinary(allocator: std.mem.Allocator, source_path: []const u8, installed_path: []const u8) !void {
    const bin_dir = std.fs.path.dirname(installed_path) orelse return error.InvalidPath;
    const staged_path = try std.fs.path.join(allocator, &.{ bin_dir, "pmm3.new" });

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

fn runInstalledSetup(allocator: std.mem.Allocator, installed_binary: []const u8) !void {
    logging.info("Running setup with {s}", .{installed_binary});

    var child = std.process.Child.init(&.{ installed_binary, "setup" }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
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

    const selected = try selectLatestRelease(std.testing.allocator, &releases, asset_name);
    defer {
        std.testing.allocator.free(selected.version);
        std.testing.allocator.free(selected.asset_name);
        std.testing.allocator.free(selected.download_url);
    }

    try std.testing.expectEqualStrings("1.2.4-alpha.2", selected.version);
    try std.testing.expectEqualStrings("https://example.com/v1.2.4-alpha.2.tar.gz", selected.download_url);
}

test "fetchLatestPmmRelease selection prefers stable over same core prerelease" {
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

    const selected = try selectLatestRelease(std.testing.allocator, &releases, asset_name);
    defer {
        std.testing.allocator.free(selected.version);
        std.testing.allocator.free(selected.asset_name);
        std.testing.allocator.free(selected.download_url);
    }

    try std.testing.expectEqualStrings("1.2.4", selected.version);
}

test "fetchLatestPmmRelease selection skips drafts and missing assets" {
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

    const selected = try selectLatestRelease(std.testing.allocator, &releases, asset_name);
    defer {
        std.testing.allocator.free(selected.version);
        std.testing.allocator.free(selected.asset_name);
        std.testing.allocator.free(selected.download_url);
    }

    try std.testing.expectEqualStrings("1.2.3", selected.version);
}

fn installPackageManager(
    allocator: std.mem.Allocator,
    package_spec: types.PackageManagerSpec,
    skip_cache: bool,
) !bool {
    if (spec.isNativePackageManager(package_spec.name)) {
        return bun.installPackageManager(allocator, package_spec, skip_cache);
    }

    const install_path = try paths.getInstallPath(allocator, package_spec);
    const temp_dir = try createTempDir(allocator);
    defer cleanupTempDir(allocator, temp_dir);

    const package_json_path = try paths.getInstallPackageJsonPath(allocator, package_spec);

    if (!skip_cache and (try paths.readFileIfPresent(allocator, package_json_path)) != null) {
        return true;
    }

    const resolved_version = try spec.getVersionCore(package_spec.version);
    const package_source = try resolvePackageSource(package_spec.name, package_spec.version);
    const tarball_url = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/-/{s}-{s}.tgz",
        .{
            try paths.getRegistry(allocator),
            package_source.registry_package_name,
            package_source.tarball_package_name,
            resolved_version,
        },
    );
    const archive_path = try std.fs.path.join(allocator, &.{ temp_dir, "package.tgz" });

    logging.friendly("Installing {s}@{s}", .{ package_spec.name, package_spec.version });

    try paths.removeTreeAbsoluteIfPresent(allocator, install_path);
    try paths.makePathAbsolute(allocator, install_path);
    try downloadFile(allocator, tarball_url, archive_path);
    try extractTarball(allocator, archive_path, install_path, 1);

    if ((try paths.readFileIfPresent(allocator, package_json_path)) == null) {
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

fn fetchUrlToMemory(allocator: std.mem.Allocator, url: []const u8, headers: RequestHeaders) ![]u8 {
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

fn fetchUrlToFile(allocator: std.mem.Allocator, url: []const u8, headers: RequestHeaders, output_path: []const u8) !void {
    const output_dir = std.fs.path.dirname(output_path) orelse return error.InvalidPath;
    try paths.makePathAbsolute(allocator, output_dir);

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
    const encoded = try encodePackageNameForRegistryPath(std.testing.allocator, "@yarnpkg/cli-dist");
    defer if (!std.mem.eql(u8, encoded, "@yarnpkg/cli-dist")) std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("@yarnpkg%2Fcli-dist", encoded);
}

test "findExtractedBinary walks nested directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("nested/bin");
    const file = try tmp.dir.createFile("nested/bin/pmm3", .{});
    file.close();

    const absolute_tmp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(absolute_tmp);

    const found = try findExtractedBinary(std.testing.allocator, absolute_tmp);
    defer std.testing.allocator.free(found);

    const expected = try std.fs.path.join(std.testing.allocator, &.{ absolute_tmp, "nested/bin/pmm3" });
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, found);
}

fn getExecutablePath(
    allocator: std.mem.Allocator,
    package_spec: types.PackageManagerSpec,
    executable_name: []const u8,
) ![]const u8 {
    if (spec.isNativePackageManager(package_spec.name)) {
        return try bun.getExecutablePath(allocator, package_spec, executable_name);
    }

    const package_json_path = try paths.getInstallPackageJsonPath(allocator, package_spec);
    const relative_path = (try package_json.readPackageExecutablePath(allocator, package_json_path, executable_name)) orelse {
        return error.CommandFailed;
    };
    const install_path = try paths.getInstallPath(allocator, package_spec);
    return try std.fs.path.join(allocator, &.{ install_path, relative_path });
}
