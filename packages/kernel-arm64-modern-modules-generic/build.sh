#!/bin/bash
# kernel-arm64-modern-modules-generic — build all modules, keep the
# COMPLEMENT of modules-soc (net, usb, hid, sound, fs, crypto, block,
# input, scsi, …).
set -euo pipefail
. /workspace/scripts/kernel-helpers.sh

PREP_TAR=/workspace/kernel-prep-in/kernel-prep.tar.zst
[[ -f "$PREP_TAR" ]] || { echo "ERROR: missing $PREP_TAR" >&2; exit 1; }
mkdir -p /workspace/src-kernel
tar -I zstd -xf "$PREP_TAR" -C /workspace
cd /workspace/src-kernel

KVER=$(make kernelversion)
echo "Building generic modules (arm64-modern) for kernel $KVER..."

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=10G
ccache -z
make ARCH=arm64 -j"$(nproc)" modules
ccache -s

STAGE=/workspace/.modules-stage
mkdir -p "$STAGE"
make ARCH=arm64 INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install

# Same SoC whitelist as kernel-arm64-modern-modules-soc. We keep the
# COMPLEMENT here.
SOC_DIRS=(
  drivers/gpu
  drivers/soc/qcom drivers/soc/rockchip drivers/soc/samsung
  drivers/clk/qcom drivers/clk/rockchip drivers/clk/samsung
  drivers/pinctrl/qcom drivers/pinctrl/rockchip
  drivers/firmware/qcom drivers/firmware
  drivers/cpufreq drivers/cpuidle
  drivers/regulator drivers/iommu drivers/extcon drivers/thermal
  drivers/i2c drivers/leds drivers/power drivers/spmi
)

OUT=/workspace/kernel-modules-out
mkdir -p "$OUT/lib/modules/${KVER}"
cp -a "$STAGE/lib/modules/${KVER}/." "$OUT/lib/modules/${KVER}/" 2>/dev/null || true

KERNEL_TREE="$OUT/lib/modules/${KVER}/kernel"
if [[ -d "$KERNEL_TREE" ]]; then
  pushd "$KERNEL_TREE" >/dev/null
  for d in "${SOC_DIRS[@]}"; do
    rm -rf "$d" 2>/dev/null || true
  done
  popd >/dev/null
fi

echo "Generic modules retained:"
find "$OUT/lib/modules/${KVER}/kernel" -name '*.ko*' 2>/dev/null | wc -l
echo "completed" > /workspace/build-status
