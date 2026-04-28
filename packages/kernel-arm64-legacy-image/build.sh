#!/bin/bash
# kernel-arm64-legacy-image — extract prep tarball, build Image + DTBs.
set -euo pipefail
. /workspace/scripts/kernel-helpers.sh

PREP_TAR=/workspace/kernel-prep-in/kernel-prep.tar.zst
[[ -f "$PREP_TAR" ]] || { echo "ERROR: missing $PREP_TAR" >&2; exit 1; }
mkdir -p /workspace/src-kernel
tar -I zstd -xf "$PREP_TAR" -C /workspace
cd /workspace/src-kernel

KVER=$(make kernelversion)
echo "Building Image + DTBs for kernel $KVER..."

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=10G
ccache -z

make ARCH=arm64 -j"$(nproc)" Image dtbs
ccache -s

OUT=/workspace/kernel-image-out/boot
mkdir -p "$OUT"
cp arch/arm64/boot/Image  "$OUT/vmlinuz-${KVER}-arm64-legacy"
cp System.map             "$OUT/System.map-${KVER}-arm64-legacy"
cp .config                "$OUT/config-${KVER}-arm64-legacy"

# DTBs go under /usr/lib/linux-image-<KVER>/dtbs/<vendor>/. The aggregator
# splits them off into the dtbs sub-package.
DTB_OUT=/workspace/kernel-image-out/dtbs
mkdir -p "$DTB_OUT"
find arch/arm64/boot/dts -name '*.dtb' -exec cp --parents {} "$DTB_OUT/" \;

echo "$KVER" > /workspace/kernel-image-out/KVER
echo "completed" > /workspace/build-status
echo "Image:  $(stat -c%s "$OUT/vmlinuz-${KVER}-arm64-legacy") bytes"
echo "DTBs:   $(find "$DTB_OUT" -name '*.dtb' | wc -l) files"
