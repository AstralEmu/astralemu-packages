#!/bin/bash
# kernel-helpers.sh — shared helpers for the kernel-* build scripts.
#
# Sourced by every packages/kernel-*/build.sh (and sub-builds prep, image,
# modules-platform, modules-generic). Keeps the build.sh files short and
# the source-of-truth values centralised.
#
# Required env from build-chain.yml:
#   TARGET_ID, TARGET_ARCH, TARGET_CFLAGS, TARGET_CXXFLAGS, SOURCE_DISTRO
#
# Optional env from the caller:
#   KERNEL_FLAVOR  — name suffix in /boot/vmlinuz-<KVER><FLAVOR> (default: empty)
set -euo pipefail

# ----------------------------------------------------------------------------
# Resolve the kernel version pin dynamically from ROCKNIX upstream.
#
# ROCKNIX is the project we follow for the upstream kernel base (it carries
# the SoC patches we cherry-pick for arm64 anyway, and pinning all our
# kernels on the same upstream base is the cleanest way to keep BORE +
# CachyOS patches applying cleanly across targets).
#
# package.mk has multiple PKG_VERSION lines (mainline / raspberrypi /
# default) — we pick the "default" one (kernel.org tarball, e.g. "6.15.6").
# Caller can override via $KERNEL_VERSION_OVERRIDE for testing.
# ----------------------------------------------------------------------------
resolve_kernel_version() {
  if [[ -n "${KERNEL_VERSION_OVERRIDE:-}" ]]; then
    echo "$KERNEL_VERSION_OVERRIDE"
    return
  fi
  local pkg_mk_url="https://raw.githubusercontent.com/ROCKNIX/distribution/next/packages/linux/package.mk"
  # Look for the line ending in a kernel.org tarball pattern (vN.x/linux-N.M.K.tar.xz)
  # and extract its PKG_VERSION value.
  local kver
  kver=$(curl -fsSL "$pkg_mk_url" \
    | awk '
        /^[[:space:]]*PKG_VERSION="[0-9]+\.[0-9]+\.[0-9]+"/ {
          gsub(/.*PKG_VERSION="|".*/, "")
          print
          exit
        }')
  if [[ -z "$kver" ]]; then
    echo "ERROR: failed to resolve kernel version from ROCKNIX package.mk" >&2
    exit 1
  fi
  echo "$kver"
}

# ----------------------------------------------------------------------------
# Clone a stable Linux source tree at the given version into /workspace/src-kernel.
# Skip the clone if it's already there at the right version (CI ccache reuses
# the workspace between sub-jobs of the same chain).
# ----------------------------------------------------------------------------
clone_linux_stable() {
  local kver="$1"
  local dest="${2:-/workspace/src-kernel}"
  local v_major="${kver%%.*}"
  local url="https://cdn.kernel.org/pub/linux/kernel/v${v_major}.x/linux-${kver}.tar.xz"

  if [[ -f "$dest/Makefile" ]]; then
    local got_kver
    got_kver=$(awk '/^VERSION = / {v=$3} /^PATCHLEVEL = / {p=$3} /^SUBLEVEL = / {s=$3} END {print v"."p"."s}' "$dest/Makefile")
    if [[ "$got_kver" == "$kver" ]]; then
      echo "Reusing existing kernel source tree at $dest ($got_kver)"
      return
    fi
    echo "Existing kernel source is $got_kver, need $kver — re-extracting"
    rm -rf "$dest"
  fi

  mkdir -p "$dest"
  echo "Fetching Linux $kver from kernel.org..."
  curl -fsSL "$url" | tar xJ --strip-components=1 -C "$dest"
}

# ----------------------------------------------------------------------------
# Apply every *.patch under <patches_dir> in lexicographic order. Refuses
# to skip individual patches — kernel build is sensitive enough that a
# silent skip would produce a kernel that boots but misbehaves at runtime,
# better fail loudly. Caller decides which dirs to apply (BORE, CachyOS,
# soc-downstream/<SoC>, handheld-extras).
# ----------------------------------------------------------------------------
apply_patches_dir() {
  local patches_dir="$1"
  local src_dir="${2:-/workspace/src-kernel}"
  [[ -d "$patches_dir" ]] || return 0
  local count=0
  local p
  for p in $(find "$patches_dir" -maxdepth 1 -name '*.patch' | sort); do
    echo "  apply $(basename "$p")"
    ( cd "$src_dir" && patch -p1 --no-backup-if-mismatch < "$p" )
    count=$((count + 1))
  done
  echo "  -> $count patches applied from $patches_dir"
}

# ----------------------------------------------------------------------------
# Fetch BORE scheduler patches matching the kernel major.minor.
#   $1 — kernel version (e.g. 6.12.4)
#   $2 — output dir (e.g. /workspace/src-kernel-patches/bore)
# BORE upstream tags follow vN.M-bore-stable-X. We pick the latest tag whose
# major.minor matches; if none exists we fall back to the closest lower one.
# ----------------------------------------------------------------------------
fetch_bore_patches() {
  local kver="$1"
  local out="$2"
  local kmm
  kmm=$(echo "$kver" | cut -d. -f1-2)
  mkdir -p "$out"
  rm -rf "$out"/*.patch
  echo "Fetching BORE for kernel $kmm..."
  if [[ ! -d /workspace/src-bore ]]; then
    git clone --depth 1 https://github.com/firelzrd/bore-scheduler.git /workspace/src-bore
  fi
  # The repo holds patches per kernel major.minor under patches/stable/v<MM>/
  local bore_dir="/workspace/src-bore/patches/stable/v${kmm}"
  if [[ ! -d "$bore_dir" ]]; then
    echo "  WARN: no BORE patches for v${kmm}; falling back to closest lower" >&2
    bore_dir=$(find /workspace/src-bore/patches/stable -maxdepth 1 -type d -name 'v*' \
      | sort -V | awk -v target="v${kmm}" '$0 <= "/workspace/src-bore/patches/stable/" target' \
      | tail -n1)
    [[ -n "$bore_dir" ]] || { echo "ERROR: no BORE patches at all" >&2; exit 1; }
    echo "  using $bore_dir"
  fi
  cp "$bore_dir"/*.patch "$out/"
}

# ----------------------------------------------------------------------------
# Fetch CachyOS handheld + portable patches matching the kernel.
#   $1 — kernel version
#   $2 — output dir
# We pick the patches that make sense across all our kernels (scheduler
# tweaks, mm/vm, fixes/) and skip CPU-specific x86 ones in arm64 callers
# via the optional $3 = "arm64" filter.
# ----------------------------------------------------------------------------
fetch_cachyos_patches() {
  local kver="$1"
  local out="$2"
  local arch_filter="${3:-}"
  local kmm
  kmm=$(echo "$kver" | cut -d. -f1-2)
  mkdir -p "$out"
  rm -rf "$out"/*.patch
  echo "Fetching CachyOS portable patches for $kmm..."
  if [[ ! -d /workspace/src-cachyos ]]; then
    git clone --depth 1 https://github.com/CachyOS/kernel-patches.git /workspace/src-cachyos
  fi
  local cachy_dir="/workspace/src-cachyos/${kmm}"
  if [[ ! -d "$cachy_dir" ]]; then
    echo "  WARN: no CachyOS patches for $kmm; falling back to closest lower" >&2
    cachy_dir=$(find /workspace/src-cachyos -maxdepth 1 -type d -name '[0-9]*.[0-9]*' \
      | sort -V | awk -v t="$kmm" '$0 <= "/workspace/src-cachyos/" t' | tail -n1)
    [[ -n "$cachy_dir" ]] || { echo "ERROR: no CachyOS patches" >&2; exit 1; }
    echo "  using $cachy_dir"
  fi
  # Allowlist: patches whose names match these patterns are kept across both
  # arches. Architecture-specific (x86 only) patches are filtered out for
  # arm64 callers.
  local pat
  for pat in "$cachy_dir"/*.patch; do
    [[ -f "$pat" ]] || continue
    local base
    base=$(basename "$pat")
    case "$base" in
      *amd-pstate*|*x86*|*intel*|*autofdo*|*propeller*)
        if [[ "$arch_filter" == "arm64" ]]; then
          echo "  skip $base (x86-only, arm64 caller)"
          continue
        fi ;;
    esac
    cp "$pat" "$out/"
  done
}

# ----------------------------------------------------------------------------
# Pretty version suffix for the package: <kver>+<short_hash> where the hash
# is the build hash from the env (SHORT, populated by compute-chains.sh for
# hash-only packages — kernel packages are hash-only).
# ----------------------------------------------------------------------------
kernel_pkg_version() {
  local kver="$1"
  echo "${kver}+${SHORT:-0000000}"
}
