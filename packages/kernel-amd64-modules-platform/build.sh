#!/bin/bash
# kernel-amd64-modules-platform — build all modules, then keep only the
# AMD/Intel/GPU/firmware/platform subset for this artifact. The complement
# is uploaded by the modules-generic sub-job; the aggregator merges both.
set -euo pipefail
. /workspace/scripts/kernel-helpers.sh

PREP_TAR=/workspace/kernel-prep-in/kernel-prep.tar.zst
[[ -f "$PREP_TAR" ]] || { echo "ERROR: missing $PREP_TAR" >&2; exit 1; }
mkdir -p /workspace/src-kernel
tar -I zstd -xf "$PREP_TAR" -C /workspace
cd /workspace/src-kernel

KVER=$(make kernelversion)
echo "Building platform modules for kernel $KVER..."

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=10G
ccache -z

make ARCH=x86_64 -j"$(nproc)" modules
ccache -s

# Install everything to a staging dir, strip, then keep only the platform
# subset. INSTALL_MOD_STRIP=1 makes the resulting tree ~3x smaller.
STAGE=/workspace/.modules-stage
mkdir -p "$STAGE"
make ARCH=x86_64 INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install

# Platform whitelist for x86 handhelds (AMD APU + Intel platforms +
# everything tied to GPU/firmware/cpufreq/thermal that Steam Deck / ROG
# Ally / Legion Go / MSI Claw rely on).
KEEP_DIRS=(
  drivers/gpu                  # amdgpu, i915, nouveau, drm helpers
  drivers/platform             # platform/x86 quirks: jupiter-hw, asus-wmi, ideapad, etc.
  drivers/firmware             # cpufreq-related, smbios
  drivers/extcon
  drivers/thermal
  drivers/cpufreq
  drivers/cpuidle
  drivers/iommu                # AMD/Intel IOMMU
  drivers/pinctrl
  drivers/spmi
  drivers/regulator
  drivers/power
  drivers/leds
  drivers/i2c                  # ACPI i2c handheld controllers
)

OUT=/workspace/kernel-modules-out
mkdir -p "$OUT/lib/modules/${KVER}"
# Copy the always-required top-level files (modules.order, modules.builtin*, …)
cp -a "$STAGE/lib/modules/${KVER}/." "$OUT/lib/modules/${KVER}/" 2>/dev/null || true

# Then prune to the whitelist.
KERNEL_TREE="$OUT/lib/modules/${KVER}/kernel"
if [[ -d "$KERNEL_TREE" ]]; then
  # Build a list of dirs to remove = everything that's NOT in KEEP_DIRS.
  pushd "$KERNEL_TREE" >/dev/null
  for d in $(find . -maxdepth 2 -type d -mindepth 1 | sort -u); do
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

echo "Platform modules retained:"
find "$OUT/lib/modules/${KVER}/kernel" -name '*.ko*' 2>/dev/null | wc -l
echo "completed" > /workspace/build-status
