#!/bin/bash
# sync-rocknix-kernels.sh — Pull the per-SoC kernel patches from ROCKNIX
# into our per-target patch directories.
#
# AstralEmu fuses ROCKNIX recipes into 3 kernel packages aligned on our
# build_targets (amd64 / arm64-modern / arm64-legacy). Each ROCKNIX recipe
# contributes its downstream patches to one of those targets:
#
#   kernel-amd64        <- pc-amd-handheld
#   kernel-arm64-modern <- rk3588 + sm8550 + sm8250 + sm6115 + rk3576
#   kernel-arm64-legacy <- tegra_x1 + s922x + h700 + rk3326 + rk3566
#
# Usage:
#   scripts/sync-rocknix-kernels.sh [--target <target_id>] [--commit <sha>]
#   --target    Sync only the named target (default: all 3)
#   --commit    Pin to a specific ROCKNIX commit (default: HEAD of main)
#
# Output:
#   packages/kernel-<target>/patches/soc-downstream/<recipe>/*.patch
#   .trackers/rocknix-commit  (records the synced commit SHA)
#
# Diff-friendly: each per-recipe directory is wiped and re-populated, so
# `git diff` after running this script shows exactly what changed upstream.
# Review the diff and commit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROCKNIX_REPO="https://github.com/ROCKNIX/distribution.git"
ROCKNIX_BRANCH="next"   # ROCKNIX active development branch
# Real ROCKNIX layout (verified 2026-04-26): per-SoC patches/dts live under
# projects/ROCKNIX/devices/<SoC>/. Names are case-sensitive uppercase as in
# the repo. Tegra X1 and pc-amd-handheld are NOT in ROCKNIX — handled by
# kernel-tegra-x1 (NaGaa95 source) and kernel-amd64 (Valve linux-jupiter +
# CachyOS) respectively. See docs/tegra-x1-research.md and
# docs/kernel-integration-plan.md.
declare -A TARGET_RECIPES=(
  [arm64-modern]="RK3588 SM8550 SM8250 SM6115 RK3576 SM8650"
  [arm64-legacy]="H700 RK3326 RK3566 RK3399 S922X"
)

ONLY_TARGET=""
PIN_COMMIT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) ONLY_TARGET="$2"; shift 2 ;;
    --commit) PIN_COMMIT="$2";  shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Shallow clone (or refresh) into a tmpdir so the working tree stays clean.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "Cloning ROCKNIX (shallow)..."
git -C "$WORK" clone --depth 1 --branch "$ROCKNIX_BRANCH" "$ROCKNIX_REPO" distribution
ROCKNIX_DIR="$WORK/distribution"

if [[ -n "$PIN_COMMIT" ]]; then
  echo "Checking out ROCKNIX commit $PIN_COMMIT..."
  git -C "$ROCKNIX_DIR" fetch --depth 1 origin "$PIN_COMMIT"
  git -C "$ROCKNIX_DIR" checkout "$PIN_COMMIT"
fi

ROCKNIX_HEAD=$(git -C "$ROCKNIX_DIR" rev-parse HEAD)
echo "ROCKNIX HEAD = $ROCKNIX_HEAD"

sync_target() {
  local target="$1"
  local recipes="${TARGET_RECIPES[$target]}"
  local pkg_dir="$ROOT_DIR/packages/kernel-$target/patches/soc-downstream"

  echo
  echo "=== $target — recipes: $recipes ==="
  mkdir -p "$pkg_dir"

  local recipe
  for recipe in $recipes; do
    # ROCKNIX puts each SoC's patches at projects/ROCKNIX/devices/<SoC>/patches/
    # and DTBs at projects/ROCKNIX/devices/<SoC>/linux/dts/<vendor>/
    local src="$ROCKNIX_DIR/projects/ROCKNIX/devices/$recipe/patches"
    local dst="$pkg_dir/$recipe"
    if [[ ! -d "$src" ]]; then
      echo "  $recipe: no patches/ dir in ROCKNIX, skipping"
      continue
    fi
    local patch_count
    patch_count=$(find "$src" -name '*.patch' 2>/dev/null | wc -l)
    echo "  $recipe: $patch_count patches"
    rm -rf "$dst"
    mkdir -p "$dst"
    # Only copy actual patches (recipes sometimes include README, etc.)
    find "$src" -name '*.patch' -exec cp {} "$dst/" \;
    # Also pull the SoC-specific DTS/DTSI files. Each kernel-<target>/build.sh
    # decides whether to copy them into arch/arm64/boot/dts/<vendor>/ before
    # build, depending on which DTBs are needed for that target's devices.
    local dts_dir="$ROCKNIX_DIR/projects/ROCKNIX/devices/$recipe/linux/dts"
    if [[ -d "$dts_dir" ]]; then
      local dts_count
      dts_count=$(find "$dts_dir" -type f | wc -l)
      echo "    + $dts_count dts files"
      mkdir -p "$dst/dts"
      cp -a "$dts_dir"/. "$dst/dts/"
    fi
  done
}

if [[ -n "$ONLY_TARGET" ]]; then
  [[ -n "${TARGET_RECIPES[$ONLY_TARGET]:-}" ]] || {
    echo "Unknown target: $ONLY_TARGET (known: ${!TARGET_RECIPES[*]})" >&2
    exit 1
  }
  sync_target "$ONLY_TARGET"
else
  for t in "${!TARGET_RECIPES[@]}"; do
    sync_target "$t"
  done
fi

# Track which ROCKNIX commit we're synced to, for traceability.
mkdir -p "$ROOT_DIR/.trackers"
echo "$ROCKNIX_HEAD" > "$ROOT_DIR/.trackers/rocknix-commit"
echo
echo "Done. ROCKNIX commit recorded in .trackers/rocknix-commit."
echo "Review the diff with:  git status; git diff packages/kernel-*/patches/"
