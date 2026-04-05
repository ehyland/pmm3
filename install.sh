#!/bin/bash

set -euo pipefail

REPOSITORY="ehyland/pmm3"
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

require_command curl
require_command tar
require_command mktemp
require_command find

OS="$(detect_os)"
ARCH="$(detect_arch)"
ASSET_NAME="pmm3-${OS}-${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPOSITORY}/releases/latest/download/${ASSET_NAME}"
ARCHIVE_PATH="$TMP_DIR/$ASSET_NAME"
EXTRACT_DIR="$TMP_DIR/extract"

mkdir -p "$PMM_BIN_DIR" "$EXTRACT_DIR"

echo "Installing pmm3"
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
