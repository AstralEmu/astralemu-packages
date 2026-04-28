#!/bin/bash
# kernel-amd64-image — extract the prep tarball, build bzImage,
# stage /boot/{vmlinuz,System.map,config} for the aggregator.
set -euo pipefail
. /workspace/scripts/kernel-helpers.sh

# build-chain.yml drops the prep artifact into kernel-prep-in/. There may
# be more than one if we ever add a fallback download — just take the
# expected name.
PREP_TAR=/workspace/kernel-prep-in/kernel-prep.tar.zst
[[ -f "$PREP_TAR" ]] || {
  echo "ERROR: missing $PREP_TAR (kernel-amd64-prep didn't run or artifact didn't propagate)" >&2
  exit 1
}

mkdir -p /workspace/src-kernel
tar -I zstd -xf "$PREP_TAR" -C /workspace --strip-components=0
cd /workspace/src-kernel

KVER=$(make kernelversion)
echo "Building bzImage for kernel $KVER..."

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=10G
ccache -z

make ARCH=x86_64 -j"$(nproc)" bzImage
ccache -s

# Stage the boot artifacts. The aggregator copies these into
# /tmp/pkg/root/boot/ alongside the modules.
OUT=/workspace/kernel-image-out/boot
mkdir -p "$OUT"
cp arch/x86/boot/bzImage "$OUT/vmlinuz-${KVER}-amd64"
cp System.map            "$OUT/System.map-${KVER}-amd64"
cp .config               "$OUT/config-${KVER}-amd64"

# Pass the version downstream (the aggregator reads this).
echo "$KVER" > /workspace/kernel-image-out/KVER
echo "completed" > /workspace/build-status
ls -lh "$OUT/"
