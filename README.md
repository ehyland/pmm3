# PMM in Zig

This workspace recreates the core behavior of [ehyland/pmm](https://github.com/ehyland/pmm), but as a Zig executable.

The binary behaves as both:

- `pmm3`, the management CLI
- `npm`, `npx`, `pnpm`, `pnpx`, and `yarn`, via shim symlinks

Like the original project, it:

- Resolves the active `packageManager` field by walking up from the current working directory
- Falls back to a cached global default when no project-level spec is present
- Downloads package manager tarballs into `PMM_DIR/installed-versions`
- Executes the selected package manager with Node.js

## Status

This is a Zig port of pmm that is intended to be distributed as a prebuilt release binary. It keeps the runtime model and command surface of the original project while using GitHub release assets for bootstrap install and self-update under the `pmm3` executable name.

Implemented commands:

- `pmm3 update-local`
- `pmm3 update-default [package-manager] [version]`
- `pmm3 update-self`
- `pmm3 setup`
- `pmm3 pin <package-manager> <path-to-package>`

Implemented shims:

- `npm`
- `npx`
- `pnpm`
- `pnpx`
- `yarn`

## Requirements

- Node.js installed locally

For the Zig binary runtime, no external `curl`, `tar`, or shell subprocesses are required.
The bootstrap installer in `install.sh` still uses shell tools.

## Build

```bash
zig build
```

The executable is written to `zig-out/bin/pmm3`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ehyland/pmm3/main/install.sh | bash
```

The install script:

- downloads the latest GitHub release asset for the current OS and architecture
- installs `pmm3` into `$PMM3_HOME/bin/pmm3`
- runs `pmm3 setup` to finish installation

You can also run setup directly from the binary:

```bash
./zig-out/bin/pmm3 setup
```

The setup command:

- installs the current `pmm3` binary into `$PMM3_HOME/bin/pmm3`
- creates or refreshes shim links for `npm`, `npx`, `pnpm`, `pnpx`, and `yarn` in `$PMM3_HOME/bin`
- appends a `pmm3` shell hook to `~/.bashrc` if one is not already present

The shell hook added to `~/.bashrc` ensures `PMM3_HOME` defaults to `~/.pmm3` and that `$PMM3_HOME/bin` is present in `PATH`.

## Self-update

`pmm3 update-self` checks the latest GitHub release, compares it to the current embedded pmm3 version, downloads the matching OS and architecture tarball when a newer version exists, replaces the installed binary in `$PMM3_HOME/bin/pmm3`, and reruns `pmm3 setup`.

Release assets are expected to follow the naming convention `pmm3-<os>-<arch>.tar.gz`, for example `pmm3-darwin-arm64.tar.gz`, and each archive must contain a `pmm3` executable.

## Releases

Alpha releases are driven by git tags and published through GitHub Actions.

To create and push the next prerelease tag locally:

```bash
./create_prerelease.sh
```

The script:

- runs `zig build test`
- runs `bun test`
- computes the next prerelease tag from the latest `v*` tag
- creates and pushes the tag after confirmation

If the latest tag is already a prerelease, the script increments that prerelease number.
If the latest tag is stable, the script increments the patch version and starts `alpha.1`.

Pushing a `v*` tag triggers `.github/workflows/release.yml`, which runs GoReleaser to:

- run the test commands before packaging
- build the Zig release binaries for macOS and Linux
- publish `pmm3-darwin-arm64.tar.gz`, `pmm3-darwin-x64.tar.gz`, `pmm3-linux-arm64.tar.gz`, and `pmm3-linux-x64.tar.gz`
- upload matching SHA256 checksum files to the GitHub Release for that tag

## Notes

- Package manager archives are stored under `$PMM3_HOME/installed-versions/<name>-<version>`.
- Default fallback versions are stored under `$PMM3_HOME/installed-versions/.defaults/<name>-version`.
- Latest Yarn resolution and installs for `yarn@2+` use `@yarnpkg/cli-dist` under the hood.
- `packageManager` specs may include a `+sha...` suffix, such as `yarn@3.2.3+sha224...`; pmm3 preserves the suffix but does not validate it.