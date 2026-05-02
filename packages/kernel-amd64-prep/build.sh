#!/bin/bash
# kernel-amd64-prep — fetch Linux source, apply BORE + CachyOS portable
# patches + the CachyOS handheld driver patch, run savedefconfig, tarball
# the patched tree for downstream sub-jobs (image, modules-platform,
# modules-generic).
#
# Handheld driver coverage (Steam Deck hwmon/LEDs/extcon/mfd, ROG Ally,
# Legion Go, MSI Claw, Zotac Zone, AMDGPU display quirks, AW87xxx audio
# codec) comes from CachyOS/kernel-patches' `<X.Y>/misc/0001-handheld.patch`,
# pulled in by fetch_cachyos_patches() since it added the misc/ scan.
# This replaces the previously planned ValveSoftware/linux-integration
# cherry-picks: the Valve repo was deleted from GitHub and the SteamOS
# Holo gitlab.steamos.cloud mirror requires authenticated access. The two
# unique features Valve used to add (AMD P-State EPP, NTSYNC) have been
# upstream since 6.18-6.19, so nothing functional regresses.
set -euo pipefail
. /workspace/scripts/kernel-helpers.sh

KVER=$(resolve_kernel_version)
echo "Kernel version pinned by ROCKNIX: $KVER"
clone_linux_stable "$KVER" /workspace/src-kernel
cd /workspace/src-kernel

# --- Patches (out-of-tree, fetched dynamically) ----------------------------
PDIR=/workspace/src-kernel-patches
mkdir -p "$PDIR"
fetch_bore_patches      "$KVER" "$PDIR/bore"
fetch_cachyos_patches   "$KVER" "$PDIR/cachyos"

# --- Apply ---
apply_patches_dir "$PDIR/bore"            /workspace/src-kernel
apply_patches_dir "$PDIR/cachyos"         /workspace/src-kernel
# Local extras (project-specific tweaks for handhelds) live in the
# aggregator directory — same shape as soc-downstream/ in arm64 targets.
apply_patches_dir /workspace/packages/kernel-amd64/patches/handheld-extras \
  /workspace/src-kernel

# --- Configure ---
# Start from the upstream x86_64 defconfig, then layer our overrides
# (CONFIG_HZ=1000, CONFIG_PREEMPT=y, BORE on, CachyOS knobs, AMD P-State EPP
# now upstream, HDR / handheld driver opts from the CachyOS handheld patch,
# Waydroid prerequisites).
make ARCH=x86_64 x86_64_defconfig
if [[ -f /workspace/packages/kernel-amd64/config/defconfig.fragment ]]; then
  scripts/kconfig/merge_config.sh -m -O . .config \
    /workspace/packages/kernel-amd64/config/defconfig.fragment
  make ARCH=x86_64 olddefconfig
fi

# --- Tarball for downstream sub-jobs ---
echo "Packing patched source + .config..."
cd /workspace
tar -I 'zstd -T0 -19' -cf kernel-prep.tar.zst -C /workspace src-kernel
echo "completed" > /workspace/build-status
ls -lh /workspace/kernel-prep.tar.zst
