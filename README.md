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

## Notes

- Package manager archives are stored under `$PMM3_HOME/installed-versions/<name>-<version>`.
- Default fallback versions are stored under `$PMM3_HOME/installed-versions/.defaults/<name>-version`.
- `yarn@2+` project specs fall back to the default installed yarn version, preserving the original project behavior around Yarn Berry projects.