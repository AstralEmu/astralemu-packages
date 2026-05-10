#!/bin/bash
# kernel-amd64-prep — fetch CachyOS kernel source (already patched with BORE,
# handheld drivers, amd-pstate, fixes, etc.), configure, and tarball the tree
# for downstream sub-jobs (image, modules-platform, modules-generic).
#
# The CachyOS/linux <X.Y>/cachy branches ship a complete kernel source with all
# their patches already merged. This replaces the previous approach of
# downloading vanilla mainline + applying individual CachyOS patches that
# frequently reference CachyOS-internal kernel APIs not present in mainline.
#
# Handheld driver coverage (Steam Deck hwmon/LEDs/extcon/mfd, ROG Ally,
# Legion Go, MSI Claw, Zotac Zone, AMDGPU display quirks, AW87xxx audio
# codec) is included in the CachyOS kernel source automatically.
#
# NOTE: Any change to scripts/kernel-helpers.sh must bump this comment to
# invalidate the cache marker, since compute-chains.sh only hashes build.sh
# + YAML entry (not sourced scripts).
# v2: resolve_cachyos_branch excludes merge-window branches (Y==0).
set -euo pipefail
. /workspace/scripts/kernel-helpers.sh

clone_cachyos_kernel /workspace/src-kernel
cd /workspace/src-kernel

KVER=$(awk '/^VERSION = / {v=$3} /^PATCHLEVEL = / {p=$3} /^SUBLEVEL = / {s=$3} END {print v"."p"."s}' Makefile)
echo "Kernel base version from CachyOS source: $KVER"

# --- Apply local extras (if any) ---
# Project-specific patches that are NOT in CachyOS go here.
# The CachyOS source already includes BORE, handheld, amd-pstate, etc.
apply_patches_dir /workspace/packages/kernel-amd64/patches/handheld-extras \
  /workspace/src-kernel

# --- Configure ---
make ARCH=x86_64 x86_64_defconfig
if [[ -f /workspace/packages/kernel-amd64/config/defconfig.fragment ]]; then
  scripts/kconfig/merge_config.sh -m -O . .config \
    /workspace/packages/kernel-amd64/config/defconfig.fragment
  make ARCH=x86_64 olddefconfig
fi

# --- Tarball for downstream sub-jobs ---
echo "Packing CachyOS kernel source + .config..."
cd /workspace
tar -I 'zstd -T0 -19' -cf kernel-prep.tar.zst -C /workspace src-kernel
echo "completed" > /workspace/build-status
ls -lh /workspace/kernel-prep.tar.zst