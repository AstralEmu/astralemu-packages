#!/bin/bash
# kernel-arm64-legacy-modules-soc — build all modules, keep only the
# SoC-relevant subset (Adreno/Mali GPU, Qualcomm/Rockchip clk/pinctrl/
# soc/firmware/cpufreq, drm helpers). Generic modules go into the
# modules-generic sibling sub-job.
set -euo pipefail
. /workspace/scripts/kernel-helpers.sh

PREP_TAR=/workspace/kernel-prep-in/kernel-prep.tar.zst
[[ -f "$PREP_TAR" ]] || { echo "ERROR: missing $PREP_TAR" >&2; exit 1; }
mkdir -p /workspace/src-kernel
tar -I zstd -xf "$PREP_TAR" -C /workspace
cd /workspace/src-kernel

KVER=$(make kernelversion)
echo "Building SoC modules (arm64-legacy) for kernel $KVER..."

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=10G
ccache -z
# Build vmlinux first — modpost needs vmlinux.o for symbol resolution.
make ARCH=arm64 -j"$(nproc)" vmlinux
make ARCH=arm64 -j"$(nproc)" modules
ccache -s

STAGE=/workspace/.modules-stage
mkdir -p "$STAGE"
make ARCH=arm64 INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install

# Whitelist for the SoCs covered by this target (H700, RK3326, RK3399,
# RK3566, S922X). drivers/gpu/drm/{rockchip,panfrost,lima,meson} cover
# Mali-Bifrost / Midgard / Lima / Rockchip-DRM. drivers/{soc,clk,pinctrl}/
# {rockchip,amlogic,sunxi} cover the platform glue.
KEEP_DIRS=(
  drivers/gpu
  drivers/soc/rockchip drivers/soc/amlogic drivers/soc/sunxi
  drivers/clk/rockchip drivers/clk/meson drivers/clk/sunxi
  drivers/pinctrl/rockchip drivers/pinctrl/meson drivers/pinctrl/sunxi
  drivers/firmware
  drivers/cpufreq drivers/cpuidle
  drivers/regulator
  drivers/iommu
  drivers/extcon
  drivers/thermal
  drivers/i2c
  drivers/leds
  drivers/power
  drivers/spmi
)

OUT=/workspace/kernel-modules-out
mkdir -p "$OUT/lib/modules/${KVER}"
cp -a "$STAGE/lib/modules/${KVER}/." "$OUT/lib/modules/${KVER}/" 2>/dev/null || true

KERNEL_TREE="$OUT/lib/modules/${KVER}/kernel"
if [[ -d "$KERNEL_TREE" ]]; then
  pushd "$KERNEL_TREE" >/dev/null
  for d in $(find . -maxdepth 2 -mindepth 1 -type d | sort -u); do
    rel="${d#./}"
    keep=false
    for k in "${KEEP_DIRS[@]}"; do
      if [[ "$rel" == "$k" || "$rel" == "$k/"* || "$k" == "$rel/"* ]]; then
        keep=true; break
      fi
    done
    [[ "$keep" == "false" ]] && rm -rf "$rel" 2>/dev/null || true
  done
  popd >/dev/null
fi

echo "SoC modules retained:"
find "$OUT/lib/modules/${KVER}/kernel" -name '*.ko*' 2>/dev/null | wc -l
echo "completed" > /workspace/build-status
