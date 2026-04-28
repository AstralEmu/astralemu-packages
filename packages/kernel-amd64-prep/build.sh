#!/bin/bash
# kernel-amd64-prep — fetch Linux source, apply BORE + CachyOS + Valve
# handheld patches, run savedefconfig, tarball the patched tree for
# downstream sub-jobs (image, modules-platform, modules-generic).
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

# Valve linux-jupiter handheld patches: cherry-pick the ones we want.
# Their tree is a full kernel fork; we extract only their delta vs the
# matching upstream as a single patch series via git format-patch.
if [[ ! -d /workspace/src-valve ]]; then
  git clone --filter=blob:none --no-checkout \
    https://github.com/ValveSoftware/linux-integration.git /workspace/src-valve
fi
mkdir -p "$PDIR/valve-handheld"
rm -f "$PDIR/valve-handheld"/*.patch
(
  cd /workspace/src-valve
  # Find the branch closest to our kernel version (Valve names them e.g.
  # 6.12.x-valve, 6.11.x-valve). Fall back gracefully.
  git fetch --depth 200 origin
  vbranch=$(git branch -r | awk '/origin\/[0-9]+\.[0-9]+\.x-valve/ {print $1}' \
    | sort -V | tail -n1 || true)
  if [[ -z "$vbranch" ]]; then
    echo "  WARN: no x.y.x-valve branch found, skipping Valve patches"
  else
    echo "  using $vbranch"
    git checkout -q "$vbranch"
    base=$(git merge-base HEAD "$(git rev-list --max-parents=0 HEAD | tail -n1)" 2>/dev/null || true)
    # Generate the patch series (Valve's last 200 commits typically span
    # their handheld delta atop the LTS base).
    git format-patch -200 --output-directory="$PDIR/valve-handheld" HEAD~200..HEAD || true
  fi
)

# --- Apply ---
apply_patches_dir "$PDIR/bore"            /workspace/src-kernel
apply_patches_dir "$PDIR/cachyos"         /workspace/src-kernel
apply_patches_dir "$PDIR/valve-handheld"  /workspace/src-kernel
# Local extras (project-specific tweaks for handhelds) live in the
# aggregator directory — same shape as soc-downstream/ in arm64 targets.
apply_patches_dir /workspace/packages/kernel-amd64/patches/handheld-extras \
  /workspace/src-kernel

# --- Configure ---
# Start from the upstream x86_64 defconfig, then layer our overrides
# (CONFIG_HZ=1000, CONFIG_PREEMPT=y, BORE on, CachyOS knobs, AMD P-State EPP,
# HDR amdgpu, jupiter-hw quirks, Waydroid prerequisites).
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
