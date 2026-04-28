#!/bin/bash
# kernel-amd64-modules-generic — build all modules, then keep only the
# COMPLEMENT of the platform whitelist (net, usb, hid, sound, fs, crypto,
# block, input, scsi, thermal-generic, …). The aggregator merges this with
# kernel-amd64-modules-platform.
set -euo pipefail
. /workspace/scripts/kernel-helpers.sh

PREP_TAR=/workspace/kernel-prep-in/kernel-prep.tar.zst
[[ -f "$PREP_TAR" ]] || { echo "ERROR: missing $PREP_TAR" >&2; exit 1; }
mkdir -p /workspace/src-kernel
tar -I zstd -xf "$PREP_TAR" -C /workspace
cd /workspace/src-kernel

KVER=$(make kernelversion)
echo "Building generic modules for kernel $KVER..."

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=10G
ccache -z

make ARCH=x86_64 -j"$(nproc)" modules
ccache -s

STAGE=/workspace/.modules-stage
mkdir -p "$STAGE"
make ARCH=x86_64 INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install

# Same whitelist as modules-platform; we keep the COMPLEMENT here.
PLATFORM_DIRS=(
  drivers/gpu drivers/platform drivers/firmware drivers/extcon
  drivers/thermal drivers/cpufreq drivers/cpuidle drivers/iommu
  drivers/pinctrl drivers/spmi drivers/regulator drivers/power
  drivers/leds drivers/i2c
)

OUT=/workspace/kernel-modules-out
mkdir -p "$OUT/lib/modules/${KVER}"
# Mirror the always-required top-level files. The aggregator will dedupe
# / merge if both jobs ship them — they're identical because they come from
# the same prep.tar.zst.
cp -a "$STAGE/lib/modules/${KVER}/." "$OUT/lib/modules/${KVER}/" 2>/dev/null || true

KERNEL_TREE="$OUT/lib/modules/${KVER}/kernel"
if [[ -d "$KERNEL_TREE" ]]; then
  pushd "$KERNEL_TREE" >/dev/null
  for d in "${PLATFORM_DIRS[@]}"; do
    rm -rf "$d" 2>/dev/null || true
  done
  popd >/dev/null
fi

echo "Generic modules retained:"
find "$OUT/lib/modules/${KVER}/kernel" -name '*.ko*' 2>/dev/null | wc -l
echo "completed" > /workspace/build-status
