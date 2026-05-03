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
  local failed=0
  local p
  for p in $(find "$patches_dir" -maxdepth 1 -name '*.patch' | sort); do
    echo "  apply $(basename "$p")"
    if ( cd "$src_dir" && patch -p1 --no-backup-if-mismatch < "$p" ); then
      count=$((count + 1))
    else
      # Re-apply with --force to accept partial application (remaining hunks
      # still apply; rejected hunks produce .rej files). Then resolve the
      # remaining .rej entries for Makefile/Kconfig build lines by inserting
      # them at the correct location.
      echo "  WARN: $(basename "$p") had rejected hunks, forcing partial application" >&2
      ( cd "$src_dir" && patch -p1 --no-backup-if-mismatch --force < "$p" ) || true
      count=$((count + 1))
      failed=$((failed + 1))
    fi
  done
  # Resolve leftover .rej files — out-of-tree patches commonly fail on
  # Makefile and Kcontext lines that shifted across kernel versions. For
  # build system additions (obj-*, source "") the insertion point is not
  # line-number sensitive: inserting at the end of the relevant section
  # produces a correct build even if the surrounding context changed.
  local resolved=0
  for rej in $(find "$src_dir" -name '*.rej'); do
    local target="${rej%.rej}"
    _resolve_rej "$target" "$rej" && rm -f "$rej" && resolved=$((resolved + 1))
  done
  if [[ $resolved -gt 0 ]]; then
    echo "  -> resolved $resolved rejected hunk(s) by manual insertion"
  fi
  echo "  -> $count patches applied from $patches_dir ($failed with rejected hunks)"
}

# ----------------------------------------------------------------------------
# _resolve_rej — absorb a .rej hunk into its target file.
#
# Handles the two common patterns that break across kernel version drift:
#   1. Makefile obj-* / subdir-* additions: inserts at the end of the
#      obj-* block for the same prefix (before the next blank line or
#      non-matching line) or at the end of the Makefile if no matching
#      prefix is found.
#   2. Kconfig source "..." additions: inserts before the closing endif or
#      at the end of the file.
#
# Returns 0 if the hunk was successfully resolved, 1 if it should remain
# as a .rej for manual inspection.
# ----------------------------------------------------------------------------
_resolve_rej() {
  local target="$1" rej="$2"
  [[ -f "$target" ]] || return 1

  # Extract the + lines from the rej hunk (the content that should have been
  # added). These are the lines starting with '+' (after the @@ header).
  local additions
  additions=$(sed -n '/^+[^+]/s/^+//'p "$rej")
  [[ -n "$additions" ]] || return 1

  local basename_target
  basename_target=$(basename "$target")
  local dirname_target
  dirname_target=$(dirname "$target")

  case "$basename_target" in
    Makefile|Kconfig)
      # For Makefile: find where to insert obj-* / subdir-* lines.
      # For Kconfig: find where to insert source "..." lines.
      ;;
    *)
      # Only handle Makefile and Kcontext for auto-resolution
      return 1
      ;;
  esac

  # Read additions into an array
  local -a add_lines=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && add_lines+=("$line")
  done <<< "$additions"

  if [[ ${#add_lines[@]} -eq 0 ]]; then
    return 1
  fi

  # For Makefile: insert obj-*/subdir-* lines after the last line matching
  # the same variable prefix (obj-$(CONFIG_FOO_*) → insert after
  # obj-$(CONFIG_FOO_*) lines) or at the end of file.
  # For Kconfig: insert source "" lines before the final "endif" or
  # "endmenu" or at the end of the file.
  if [[ "$basename_target" == "Makefile" ]]; then
    # Group the addition lines by their prefix pattern
    local tmp_target="${target}.tmp_resolve"
    cp "$target" "$tmp_target"

    for add_line in "${add_lines[@]}"; do
      # Extract variable prefix: obj-$(CONFIG_ASUS_ALLY) → ASUS_ALLY
      # or obj-$(CONFIG_AMD_SFH_HID) → AMD_SFH_HID
      local prefix=""
      if [[ "$add_line" =~ obj-\$\((CONFIG_[A-Z0-9_]+)\) ]]; then
        # Find the last line in the Makefile that contains an obj-* line
        # with a similar prefix or just any obj-* line, and insert after it
        local var_match="${BASH_REMATCH[1]}"
        # Find the first 3 chars of the config var for grouping
        prefix="${var_match:0:3}"
      fi
    done

    # Simpler approach: just append the additions at the end of the file.
    # Makefile order doesn't matter for obj-* lines — the build system
    # processes all of them regardless of position.
    for add_line in "${add_lines[@]}"; do
      # Don't add duplicates
      if ! grep -qF "$add_line" "$target"; then
        echo "$add_line" >> "$target"
      fi
    done
    rm -f "$tmp_target"
    echo "  resolved $(basename "$target") .rej: appended ${#add_lines[@]} build line(s)" >&2
    return 0

  elif [[ "$basename_target" == "Kconfig" ]]; then
    # For Kconfig source "" additions: insert before the final "endif" or
    # at the end. Don't add duplicates.
    for add_line in "${add_lines[@]}"; do
      if ! grep -qF "$add_line" "$target"; then
        # Find the last endif/endmenu and insert before it
        local last_endif
        last_endif=$(grep -n '^endif\|^endmenu' "$target" | tail -1 | cut -d: -f1)
        if [[ -n "$last_endif" ]]; then
          sed -i "${last_endif}i\\${add_line}" "$target"
        else
          echo "$add_line" >> "$target"
        fi
      fi
    done
    echo "  resolved $(basename "$target") .rej: inserted ${#add_lines[@]} source line(s)" >&2
    return 0
  fi

  return 1
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
  # The BORE repo ships patches for LTS + current mainline versions only.
  # Layout: patches/stable/linux-<X.Y>-bore/*.patch
  local bore_dir="/workspace/src-bore/patches/stable/linux-${kmm}-bore"
  if [[ -d "$bore_dir" ]]; then
    cp "$bore_dir"/*.patch "$out/"
    echo "  applied $(ls "$out"/*.patch 2>/dev/null | wc -l) BORE patches from $bore_dir"
    return
  fi
  # Fallback: CachyOS ships BORE scheduler patches under <X.Y>/sched/ for
  # every kernel version they maintain. Use the CachyOS BORE patch when
  # firelzrd's repo doesn't cover the current version.
  echo "  no BORE patches in firelzrd repo for linux-${kmm}-bore; checking CachyOS..."
  if [[ ! -d /workspace/src-cachyos ]]; then
    git clone --depth 1 https://github.com/CachyOS/kernel-patches.git /workspace/src-cachyos
  fi
  local cachy_bore="/workspace/src-cachyos/${kmm}/sched/0001-bore.patch"
  if [[ -f "$cachy_bore" ]]; then
    cp "$cachy_bore" "$out/"
    echo "  using CachyOS BORE patch from ${kmm}/sched/"
    return
  fi
  # Try closest lower CachyOS version
  local fallback_dir
  fallback_dir=$(find /workspace/src-cachyos -maxdepth 2 -path '*/sched/0001-bore.patch' \
    | sort -Vr | head -n1)
  if [[ -n "$fallback_dir" ]]; then
    local fallback_kmm
    fallback_kmm=$(echo "$fallback_dir" | grep -oP '\d+\.\d+(?=/sched)')
    echo "  WARN: no BORE for $kmm, using CachyOS BORE from $fallback_kmm" >&2
    cp "$fallback_dir" "$out/"
    return
  fi
  echo "ERROR: no BORE patches available for kernel $kmm anywhere" >&2
  exit 1
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

  # CachyOS also ships a monolithic "handheld" patch under <X.Y>/misc/ that
  # adds device drivers for ROG Ally, Legion Go, MSI Claw, Zotac Zone, plus
  # Steam Deck hwmon/LEDs/extcon/mfd, panel quirks, and audio codecs. This
  # patch is x86-only in practice (handhelds covered are AMD/Intel x86_64),
  # so we only copy it when the caller is x86. Skipping for arm64.
  if [[ "$arch_filter" != "arm64" && -f "$cachy_dir/misc/0001-handheld.patch" ]]; then
    cp "$cachy_dir/misc/0001-handheld.patch" "$out/9999-cachyos-handheld.patch"
    echo "  add CachyOS handheld patch (covers Steam Deck / ROG Ally / Legion Go / MSI Claw / Zotac drivers)"
  fi
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
