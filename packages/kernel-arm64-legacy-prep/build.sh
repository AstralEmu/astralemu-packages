#!/bin/bash
# kernel-arm64-legacy-prep — fetch Linux source, apply BORE + CachyOS
# (arm64 filtered) + ROCKNIX SoC downstream patches, run savedefconfig,
# tarball the patched tree.
set -euo pipefail
. /workspace/scripts/kernel-helpers.sh

KVER=$(resolve_kernel_version)
echo "Kernel version pinned by ROCKNIX: $KVER"
clone_linux_stable "$KVER" /workspace/src-kernel
cd /workspace/src-kernel

# --- Patches --------------------------------------------------------------
PDIR=/workspace/src-kernel-patches
mkdir -p "$PDIR"
fetch_bore_patches    "$KVER" "$PDIR/bore"
fetch_cachyos_patches "$KVER" "$PDIR/cachyos" arm64

# ROCKNIX SoC patches are vendored under
# packages/kernel-arm64-legacy/patches/soc-downstream/<SoC>/ by
# scripts/sync-rocknix-kernels.sh. Each SoC contributes its patches plus
# its DTS files. We apply patches first, then drop DTS into the tree.
SOC_PATCHES=/workspace/packages/kernel-arm64-legacy/patches/soc-downstream
if [[ -d "$SOC_PATCHES" ]]; then
  # Iterate in lexicographic SoC order so applies are deterministic.
  for soc_dir in "$SOC_PATCHES"/*/; do
    soc=$(basename "$soc_dir")
    [[ -d "$soc_dir" ]] || continue
    apply_patches_dir "$soc_dir" /workspace/src-kernel
    # DTS / DTSI: ROCKNIX layout exposes them under dts/<vendor>/. Copy
    # the whole tree into arch/arm64/boot/dts/ — overlay semantics: any
    # file with the same name overwrites upstream's, anything new lands
    # alongside.
    if [[ -d "$soc_dir/dts" ]]; then
      echo "  copying DTS overlays for $soc"
      cp -a "$soc_dir/dts/." /workspace/src-kernel/arch/arm64/boot/dts/
    fi
  done
fi

# --- Configure ------------------------------------------------------------
make ARCH=arm64 defconfig
if [[ -f /workspace/packages/kernel-arm64-legacy/config/defconfig.fragment ]]; then
  scripts/kconfig/merge_config.sh -m -O . .config \
    /workspace/packages/kernel-arm64-legacy/config/defconfig.fragment
  make ARCH=arm64 olddefconfig
fi

# --- Tarball --------------------------------------------------------------
echo "Packing patched source + .config..."
cd /workspace
tar -I 'zstd -T0 -19' -cf kernel-prep.tar.zst -C /workspace src-kernel
echo "completed" > /workspace/build-status
ls -lh /workspace/kernel-prep.tar.zst
