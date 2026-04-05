set -euxo pipefail

zig build
# zig build -Doptimize=ReleaseFast
rm -rf ~/.pmm3
./zig-out/bin/pmm3 setup
