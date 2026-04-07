#!/bin/bash

set -euo pipefail

REPOSITORY="ehyland/pmm3"
RELEASES_API_URL="https://api.github.com/repos/${REPOSITORY}/releases?per_page=100"
PMM3_HOME="${PMM3_HOME:-$HOME/.pmm3}"
PMM_BIN_DIR="$PMM3_HOME/bin"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required to install pmm3" >&2
    exit 1
  fi
}

detect_os() {
  case "$(uname -s)" in
    Darwin)
      echo "darwin"
      ;;
    Linux)
      echo "linux"
      ;;
    *)
      echo "Unsupported operating system: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    arm64|aarch64)
      echo "arm64"
      ;;
    x86_64|amd64)
      echo "x64"
      ;;
    *)
      echo "Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

find_extracted_binary() {
  find "$1" -type f -name pmm3 | head -n 1
}

resolve_release_info() {
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: pmm3-installer" \
    "$RELEASES_API_URL" | node - "$ASSET_NAME" <<'NODE'
const fs = require('node:fs');

const assetName = process.argv[2];
const releases = JSON.parse(fs.readFileSync(0, 'utf8'));

function normalizeVersion(rawVersion) {
  return rawVersion.replace(/^v/i, '');
}

function parseVersion(rawVersion) {
  const version = normalizeVersion(rawVersion);
  const [core] = version.split('+', 1);
  const hyphenIndex = core.indexOf('-');
  const releaseCore = hyphenIndex === -1 ? core : core.slice(0, hyphenIndex);
  const prerelease = hyphenIndex === -1 ? null : core.slice(hyphenIndex + 1);
  const parts = releaseCore.split('.');
  if (parts.length !== 3) return null;

  const [major, minor, patch] = parts.map((part) => Number.parseInt(part, 10));
  if ([major, minor, patch].some((part) => Number.isNaN(part))) return null;

  if (prerelease !== null) {
    if (prerelease.length === 0) return null;
    for (const identifier of prerelease.split('.')) {
      if (!/^[0-9A-Za-z-]+$/.test(identifier)) return null;
      if (/^\d+$/.test(identifier) && identifier.length > 1 && identifier.startsWith('0')) {
        return null;
      }
    }
  }

  return { major, minor, patch, prerelease };
}

function compareIdentifiers(left, right) {
  const leftNumeric = /^\d+$/.test(left);
  const rightNumeric = /^\d+$/.test(right);

  if (leftNumeric && rightNumeric) {
    if (left.length !== right.length) {
      return left.length < right.length ? -1 : 1;
    }
    if (left === right) return 0;
    return left < right ? -1 : 1;
  }

  if (leftNumeric) return -1;
  if (rightNumeric) return 1;
  if (left === right) return 0;
  return left < right ? -1 : 1;
}

function compareVersions(left, right) {
  for (const key of ['major', 'minor', 'patch']) {
    if (left[key] !== right[key]) {
      return left[key] < right[key] ? -1 : 1;
    }
  }

  if (left.prerelease === null && right.prerelease === null) return 0;
  if (left.prerelease === null) return 1;
  if (right.prerelease === null) return -1;

  const leftParts = left.prerelease.split('.');
  const rightParts = right.prerelease.split('.');
  const maxLength = Math.max(leftParts.length, rightParts.length);

  for (let index = 0; index < maxLength; index += 1) {
    const leftPart = leftParts[index];
    const rightPart = rightParts[index];
    if (leftPart === undefined) return -1;
    if (rightPart === undefined) return 1;

    const comparison = compareIdentifiers(leftPart, rightPart);
    if (comparison !== 0) return comparison;
  }

  return 0;
}

let bestRelease = null;

for (const release of releases) {
  if (release.draft) continue;

  const version = parseVersion(release.tag_name ?? '');
  if (version === null) continue;

  const asset = (release.assets ?? []).find((candidate) => candidate.name === assetName);
  if (!asset?.browser_download_url) continue;

  if (bestRelease === null || compareVersions(version, bestRelease.version) > 0) {
    bestRelease = {
      version,
      normalizedVersion: normalizeVersion(release.tag_name),
      downloadUrl: asset.browser_download_url,
    };
  }
}

if (bestRelease === null) {
  console.error(`Unable to find a published release containing ${assetName}`);
  process.exit(1);
}

process.stdout.write(`${bestRelease.normalizedVersion}\t${bestRelease.downloadUrl}\n`);
NODE
}

require_command curl
require_command tar
require_command mktemp
require_command find
require_command node

OS="$(detect_os)"
ARCH="$(detect_arch)"
ASSET_NAME="pmm3-${OS}-${ARCH}.tar.gz"
ARCHIVE_PATH="$TMP_DIR/$ASSET_NAME"
EXTRACT_DIR="$TMP_DIR/extract"

IFS=$'\t' read -r RELEASE_VERSION DOWNLOAD_URL <<<"$(resolve_release_info)"

mkdir -p "$PMM_BIN_DIR" "$EXTRACT_DIR"

echo "Installing pmm3"
echo "Selected release $RELEASE_VERSION"
echo "Downloading $ASSET_NAME"

curl -fsSL "$DOWNLOAD_URL" -o "$ARCHIVE_PATH"
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

EXTRACTED_BINARY="$(find_extracted_binary "$EXTRACT_DIR")"

if [[ -z "$EXTRACTED_BINARY" ]]; then
  echo "Unable to find pmm3 executable in $ASSET_NAME" >&2
  exit 1
fi

cp "$EXTRACTED_BINARY" "$PMM_BIN_DIR/pmm3"
chmod +x "$PMM_BIN_DIR/pmm3"

echo "Installed pmm3 to $PMM_BIN_DIR/pmm3"
echo "Running setup"

export PMM3_HOME
"$PMM_BIN_DIR/pmm3" setup
