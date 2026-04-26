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
ROCKNIX_BRANCH="main"

# target -> space-separated list of ROCKNIX recipe names under packages/linux/
declare -A TARGET_RECIPES=(
  [amd64]="pc-amd-handheld"
  [arm64-modern]="rk3588 sm8550 sm8250 sm6115 rk3576"
  [arm64-legacy]="tegra_x1 s922x h700 rk3326 rk3566"
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
    local src="$ROCKNIX_DIR/packages/linux/$recipe/patches"
    local dst="$pkg_dir/$recipe"
    if [[ ! -d "$src" ]]; then
      echo "  $recipe: no patches/ dir in ROCKNIX, skipping"
      continue
    fi
    echo "  $recipe: $(find "$src" -name '*.patch' | wc -l) patches"
    rm -rf "$dst"
    mkdir -p "$dst"
    # Only copy actual patches (recipes sometimes include README, etc.)
    find "$src" -name '*.patch' -exec cp {} "$dst/" \;
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
