#!/usr/bin/env bash
# Reproducible build of metis.ko for Grinn Genio700 SBC
# Kernel:  5.15.47-mtk+gd011e19cfc68 (MediaTek Genio BSP, Yocto kirkstone)
# Driver:  axelera-ai-hub/axelera-driver @ release/v1.6
#
# Prerequisites on the build host (Ubuntu 22.04):
#   sudo apt install -y build-essential bc bison flex libssl-dev \
#                       libelf-dev cpio rsync kmod dwarves \
#                       gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu git
#
# Run from the repo root:
#   ./build/build.sh
#
# Result:
#   ./deploy/metis.ko  (copied into deploy/ on success)

set -euo pipefail

# -------------------------------------------------------------------------
# Configuration (override via env if needed)
# -------------------------------------------------------------------------
MTK_KERNEL_URL="${MTK_KERNEL_URL:-https://gitlab.com/mediatek/aiot/bsp/linux.git}"
MTK_KERNEL_COMMIT="${MTK_KERNEL_COMMIT:-d011e19cfc687d78c2b46c87ba1c9fdf06e8287f}"
AXELERA_DRIVER_URL="${AXELERA_DRIVER_URL:-https://github.com/axelera-ai-hub/axelera-driver.git}"
AXELERA_DRIVER_REF="${AXELERA_DRIVER_REF:-release/v1.6}"
TARGET_UTS_RELEASE="${TARGET_UTS_RELEASE:-5.15.47-mtk+gd011e19cfc68}"

CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
ARCH="${ARCH:-arm64}"

BUILD_ROOT="${BUILD_ROOT:-$(pwd)/.build}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_DIR="${BUILD_ROOT}/mtk-linux-5.15"
DRIVER_DIR="${BUILD_ROOT}/axelera-driver"
BOARD_CONFIG="${REPO_ROOT}/build/board-full.config"
PATCH_FILE="${REPO_ROOT}/build/patches/0001-lower-dma-buf-namespace-threshold-to-5.15.patch"

# -------------------------------------------------------------------------
# Sanity
# -------------------------------------------------------------------------
for tool in git make pahole "${CROSS_COMPILE}gcc" "${CROSS_COMPILE}ld"; do
    command -v "$tool" >/dev/null || { echo "ERROR: $tool not found"; exit 1; }
done
[ -f "$BOARD_CONFIG" ] || { echo "ERROR: $BOARD_CONFIG missing (board-full.config)"; exit 1; }
[ -f "$PATCH_FILE" ]   || { echo "ERROR: $PATCH_FILE missing"; exit 1; }

mkdir -p "$BUILD_ROOT"

# -------------------------------------------------------------------------
# 1. Fetch MTK kernel at the exact Yocto build commit
# -------------------------------------------------------------------------
if [ ! -d "$KERNEL_DIR/.git" ]; then
    echo "==> Cloning MTK kernel (shallow)..."
    git clone --depth=1 --no-single-branch --branch=mtk-v5.15-dev \
        "$MTK_KERNEL_URL" "$KERNEL_DIR"
fi
pushd "$KERNEL_DIR" >/dev/null
if [ "$(git rev-parse HEAD)" != "$MTK_KERNEL_COMMIT" ]; then
    echo "==> Fetching exact commit $MTK_KERNEL_COMMIT ..."
    git fetch --depth=1 origin "$MTK_KERNEL_COMMIT"
    git checkout "$MTK_KERNEL_COMMIT"
fi
popd >/dev/null

# -------------------------------------------------------------------------
# 2. Fetch driver source and apply our patch
# -------------------------------------------------------------------------
if [ ! -d "$DRIVER_DIR/.git" ]; then
    echo "==> Cloning axelera-driver ($AXELERA_DRIVER_REF)..."
    git clone --depth=1 --branch="$AXELERA_DRIVER_REF" \
        "$AXELERA_DRIVER_URL" "$DRIVER_DIR"
fi
pushd "$DRIVER_DIR" >/dev/null
# Reset any previous modifications before applying
git checkout -- .
if ! git apply --check "$PATCH_FILE" 2>/dev/null; then
    # Already applied? Check with a reverse check.
    if git apply --check -R "$PATCH_FILE" 2>/dev/null; then
        echo "==> Patch already applied, skipping"
    else
        echo "ERROR: patch does not apply cleanly"
        exit 1
    fi
else
    echo "==> Applying DMA_BUF namespace patch..."
    git apply "$PATCH_FILE"
fi
popd >/dev/null

# -------------------------------------------------------------------------
# 3. Configure & prepare the kernel
# -------------------------------------------------------------------------
echo "==> Configuring kernel from board-full.config..."
# Disable LOCALVERSION_AUTO because the board config already encodes the
# commit hash in CONFIG_LOCALVERSION, and setlocalversion would append a
# second '+gXXXXX' suffix otherwise.
sed 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' \
    "$BOARD_CONFIG" > "$KERNEL_DIR/.config"

echo "==> make olddefconfig + modules_prepare..."
make -C "$KERNEL_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
     olddefconfig modules_prepare

# -------------------------------------------------------------------------
# 4. Force the kernel release string to match the running board exactly
# -------------------------------------------------------------------------
# setlocalversion adds a trailing '+' when the tree is "dirty" which does
# not match the board's uname -r. Pin the release string explicitly.
echo "==> Pinning UTS_RELEASE to $TARGET_UTS_RELEASE"
echo "$TARGET_UTS_RELEASE" > "$KERNEL_DIR/include/config/kernel.release"
printf '#define UTS_RELEASE "%s"\n' "$TARGET_UTS_RELEASE" \
    > "$KERNEL_DIR/include/generated/utsrelease.h"

# -------------------------------------------------------------------------
# 5. Build the module
# -------------------------------------------------------------------------
echo "==> Building metis.ko..."
make -C "$DRIVER_DIR" clean || true
make -C "$DRIVER_DIR" \
     ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
     KDIR="$KERNEL_DIR"

# -------------------------------------------------------------------------
# 6. Verify and publish
# -------------------------------------------------------------------------
VM=$(strings "$DRIVER_DIR/metis.ko" | grep '^vermagic=' | head -1)
echo "==> Built module vermagic: $VM"
if ! echo "$VM" | grep -q "$TARGET_UTS_RELEASE "; then
    echo "ERROR: vermagic mismatch (expected kernel '$TARGET_UTS_RELEASE')"
    exit 1
fi
if ! strings "$DRIVER_DIR/metis.ko" | grep -q '^import_ns=DMA_BUF$'; then
    echo "ERROR: metis.ko missing import_ns=DMA_BUF -- patch not applied?"
    exit 1
fi

cp -v "$DRIVER_DIR/metis.ko" "$REPO_ROOT/deploy/metis.ko"
echo "==> OK: $REPO_ROOT/deploy/metis.ko ($(stat -c%s "$REPO_ROOT/deploy/metis.ko") bytes)"
