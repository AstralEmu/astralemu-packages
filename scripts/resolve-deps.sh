#!/bin/bash
# resolve-deps.sh — Recursive dependency resolution across distros
#
# Checks if dependencies exist in the target distro with compatible versions
# (same major.minor.patch — bugfix/revision differences are ignored).
# Missing or incompatible deps are fetched from source, rebuilt with a prefixed
# package name (e.g. noble-libfoo) and Provides: original_name.
# The prefix defaults to SOURCE_DISTRO but can be overridden with --prefix.
# Supports --cache-dir to reuse previously fetched source packages across runs.
#
# Outputs:
#   - Rebuilt prefixed packages in OUTPUT_DIR/
#   - dep-mapping.txt in OUTPUT_DIR/ (original=prefixed, one per line)
#
# Uses batched Docker calls for efficiency + parallel local rebuild.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SOURCE_PKGS=""
SOURCE_DISTRO=""
TARGET_DISTRO=""
TARGET_FORMAT=""
DISTROS_CONFIG=""
DEP_MAP=""
OUTPUT_DIR=""
ARCH="aarch64"
SKIP_NAMES=""
DEP_PREFIX=""
EXISTING_REPO=""
CACHE_DIR=""
MAX_PARALLEL=8
MAX_PKG_SIZE=$((95 * 1024 * 1024))  # 95 MB — GitHub rejects files > 100 MB

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-pkgs)     SOURCE_PKGS="$2";     shift 2 ;;
    --source-distro)   SOURCE_DISTRO="$2";   shift 2 ;;
    --target-distro)   TARGET_DISTRO="$2";   shift 2 ;;
    --target-format)   TARGET_FORMAT="$2";   shift 2 ;;
    --distros-config)  DISTROS_CONFIG="$2";  shift 2 ;;
    --dep-map)         DEP_MAP="$2";         shift 2 ;;
    --output-dir)      OUTPUT_DIR="$2";      shift 2 ;;
    --arch)            ARCH="$2";            shift 2 ;;
    --skip-names)      SKIP_NAMES="$2";      shift 2 ;;
    --prefix)          DEP_PREFIX="$2";      shift 2 ;;
    --existing-repo)   EXISTING_REPO="$2";  shift 2 ;;
    --cache-dir)       CACHE_DIR="$2";       shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SOURCE_PKGS" || -z "$TARGET_DISTRO" || -z "$TARGET_FORMAT" || -z "$OUTPUT_DIR" ]]; then
  echo "ERROR: Missing required arguments" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
> "$OUTPUT_DIR/dep-mapping.txt"

# Make EXISTING_REPO absolute (subprocesses may run from different dirs)
if [[ -n "$EXISTING_REPO" && "$EXISTING_REPO" != /* ]]; then
  EXISTING_REPO="$(pwd)/$EXISTING_REPO"
fi

# Make CACHE_DIR absolute and ensure it exists
if [[ -n "$CACHE_DIR" && "$CACHE_DIR" != /* ]]; then
  CACHE_DIR="$(pwd)/$CACHE_DIR"
fi
if [[ -n "$CACHE_DIR" ]]; then
  mkdir -p "$CACHE_DIR"
fi

# Failure tracking
FAIL_LOG=$(mktemp)
log_fail() { echo "  FAIL: $*" >&2; echo "$*" >> "$FAIL_LOG"; }

# ========================================================================
# Skip set — our own packages to never fetch
# ========================================================================

declare -A SKIP_SET
if [[ -n "$SKIP_NAMES" && -f "$SKIP_NAMES" ]]; then
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    SKIP_SET["$name"]=1
  done < "$SKIP_NAMES"
  echo "Loaded ${#SKIP_SET[@]} own package names to skip"
fi

# ========================================================================
# Helpers
# ========================================================================

get_docker_image() {
  case "$1" in
    noble)    echo "ubuntu:24.04" ;;
    trixie)   echo "debian:trixie" ;;
    fedora41) echo "fedora:41" ;;
    arch)     echo "archlinux:latest" ;;
    *)        echo "ubuntu:24.04" ;;
  esac
}

get_source_format() {
  case "${SOURCE_DISTRO:-noble}" in
    noble|trixie) echo "deb" ;;
    fedora41)     echo "rpm" ;;
    arch)         echo "pacman" ;;
    *)            echo "deb" ;;
  esac
}

get_platform() {
  case "$ARCH" in
    aarch64) echo "linux/arm64" ;;
    x86_64)  echo "linux/amd64" ;;
    armhf)   echo "linux/arm/v7" ;;
    *)       echo "linux/arm64" ;;
  esac
}

# Extract major.minor for comparison (patch ignored)
# Returns "NONSTANDARD" for commits, dates, or non-semver formats
parse_version_pair() {
  local ver="$1"
  ver="${ver#*:}"                          # strip epoch
  ver="${ver%%-*}"                         # strip revision
  ver=$(echo "$ver" | sed 's/[+~].*//')   # strip modifiers
  local IFS='.'
  read -ra parts <<< "$ver"
  local major="${parts[0]:-}"
  local minor="${parts[1]:-}"
  # Need at least major.minor with numeric parts to be standard semver
  if ! [[ "$major" =~ ^[0-9]+$ ]] || [[ -z "$minor" ]] || ! [[ "$minor" =~ ^[0-9]+$ ]]; then
    echo "NONSTANDARD"
    return
  fi
  echo "${major}.${minor}"
}

versions_compatible() {
  local src_pair tgt_pair
  src_pair=$(parse_version_pair "$1")
  tgt_pair=$(parse_version_pair "$2")
  # Non-standard versions (commits, dates, etc.) → exact string match or mismatch
  if [[ "$src_pair" == "NONSTANDARD" || "$tgt_pair" == "NONSTANDARD" ]]; then
    local src_clean tgt_clean
    src_clean="${1#*:}"; src_clean="${src_clean%%-*}"
    tgt_clean="${2#*:}"; tgt_clean="${tgt_clean%%-*}"
    [[ "$src_clean" == "$tgt_clean" ]]
    return
  fi
  # Standard semver: major.minor must match (patch ignored)
  [[ "$src_pair" == "$tgt_pair" ]]
}

map_dep_name() {
  local dep="$1" from_format="$2" to_format="$3"

  [[ "$from_format" == "$to_format" ]] && { echo "$dep"; return; }
  [[ -z "$DEP_MAP" || ! -f "$DEP_MAP" ]] && { echo "$dep"; return; }

  local mapped=""
  case "${from_format}:${to_format}" in
    deb:rpm)    mapped=$(grep "^${dep} " "$DEP_MAP" 2>/dev/null | head -1 | grep -oP 'rpm:\K[^,\s]+' | tr -d ' ') || true ;;
    deb:pacman) mapped=$(grep "^${dep} " "$DEP_MAP" 2>/dev/null | head -1 | grep -oP 'pac:\K[^,\s]+' | tr -d ' ') || true ;;
    rpm:deb)    mapped=$(grep "rpm:${dep}" "$DEP_MAP" 2>/dev/null | head -1 | cut -d'=' -f1 | tr -d ' ') || true ;;
    rpm:pacman) mapped=$(grep "rpm:${dep}" "$DEP_MAP" 2>/dev/null | head -1 | grep -oP 'pac:\K[^,\s]+' | tr -d ' ') || true ;;
    pacman:deb) mapped=$(grep "pac:${dep}" "$DEP_MAP" 2>/dev/null | head -1 | cut -d'=' -f1 | tr -d ' ') || true ;;
    pacman:rpm) mapped=$(grep "pac:${dep}" "$DEP_MAP" 2>/dev/null | head -1 | grep -oP 'rpm:\K[^,\s]+' | tr -d ' ') || true ;;
  esac

  echo "${mapped:-$dep}"
}

limit_jobs() {
  while [[ $(jobs -rp | wc -l) -ge $MAX_PARALLEL ]]; do
    wait -n 2>/dev/null || true
  done
}

# Check if a prefixed dep already exists in the repo with a compatible version
dep_version_in_repo() {
  local prefixed="$1" new_version="$2"
  [[ -z "$EXISTING_REPO" || ! -f "$EXISTING_REPO" ]] && return 1

  local match existing_ver
  case "$TARGET_FORMAT" in
    deb)
      # Filename: prefixed_VERSION_ARCH.deb
      match=$(grep -m1 "/${prefixed}_" "$EXISTING_REPO" 2>/dev/null) || return 1
      existing_ver=$(basename "$match" | sed "s/^${prefixed}_//; s/_[^_]*\.deb$//")
      ;;
    rpm)
      # Filename: prefixed-VERSION-RELEASE.ARCH.rpm
      match=$(grep -m1 "/${prefixed}-[0-9]" "$EXISTING_REPO" 2>/dev/null) || return 1
      local stem
      stem=$(basename "$match" | sed 's/\.[^.]*\.rpm$//')
      existing_ver=$(echo "$stem" | sed "s/^${prefixed}-//" | rev | cut -d- -f2- | rev)
      ;;
    pacman)
      # Filename: prefixed-VERSION-PKGREL-ARCH.pkg.tar.zst
      match=$(grep -m1 "/${prefixed}-[0-9]" "$EXISTING_REPO" 2>/dev/null) || return 1
      local stem
      stem=$(basename "$match" | sed 's/\.pkg\.tar\.zst$//')
      existing_ver=$(echo "$stem" | rev | cut -d- -f3- | rev | sed "s/^${prefixed}-//")
      ;;
  esac

  [[ -z "$existing_ver" ]] && return 1
  versions_compatible "$new_version" "$existing_ver"
}

# ========================================================================
# Batch version query — one Docker call per distro per round
# Output: "name=version" or "name=MISSING", one per line
# ========================================================================

batch_get_versions() {
  local dep_list="$1" image="$2" format="$3"
  [[ -z "$dep_list" ]] && return

  case "$format" in
    deb)
      docker run --rm --platform "$PLATFORM" "$image" bash -c "
        apt-get update -qq >/dev/null 2>&1
        FOUND=\$(apt-cache show $dep_list 2>/dev/null | awk '/^Package:/{pkg=\$2} /^Version:/{if(!seen[pkg]){print pkg\"=\"\$2; seen[pkg]=1}}')
        echo \"\$FOUND\"
        for pkg in $dep_list; do
          echo \"\$FOUND\" | grep -q \"^\${pkg}=\" || echo \"\${pkg}=MISSING\"
        done
      " 2>/dev/null || true
      ;;
    rpm)
      docker run --rm --platform "$PLATFORM" "$image" bash -c "
        FOUND=\$(dnf repoquery --qf '%{name}=%{version}-%{release}' $dep_list 2>/dev/null)
        echo \"\$FOUND\"
        for pkg in $dep_list; do
          echo \"\$FOUND\" | grep -q \"^\${pkg}=\" || echo \"\${pkg}=MISSING\"
        done
      " 2>/dev/null || true
      ;;
    pacman)
      docker run --rm --platform "$PLATFORM" "$image" bash -c "
        pacman -Sy --noconfirm >/dev/null 2>&1
        FOUND=\$(pacman -Si $dep_list 2>/dev/null | awk '/^Name/{name=\$3} /^Version/{print name\"=\"\$3}')
        echo \"\$FOUND\"
        for pkg in $dep_list; do
          echo \"\$FOUND\" | grep -q \"^\${pkg}=\" || echo \"\${pkg}=MISSING\"
        done
      " 2>/dev/null || true
      ;;
  esac
}

# ========================================================================
# Collect deps from a built package
# ========================================================================

collect_deps_from_pkg() {
  local pkg_file="$1"
  case "$pkg_file" in
    *.deb)
      dpkg-deb -f "$pkg_file" Depends 2>/dev/null | tr ',' '\n' | \
        sed 's/([^)]*)//g; s/|.*//; s/:.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//' | \
        grep -E '^[a-zA-Z]' || true
      ;;
    *.rpm)
      rpm -qp --requires "$pkg_file" 2>/dev/null | grep -v '^rpmlib(' | grep -v '^/' | \
        sed 's/[[:space:]]*[><=].*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | \
        grep -E '^[a-zA-Z]' | sort -u || true
      ;;
    *.pkg.tar.zst|*.pkg.tar.xz|*.pkg.tar.gz)
      local tmpext
      tmpext=$(mktemp -d)
      tar xf "$pkg_file" -C "$tmpext" .PKGINFO 2>/dev/null || true
      if [[ -f "$tmpext/.PKGINFO" ]]; then
        grep '^depend = ' "$tmpext/.PKGINFO" | sed 's/^depend = //; s/[><=].*//' | \
          sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
          grep -E '^[a-zA-Z]' || true
      fi
      rm -rf "$tmpext"
      ;;
  esac
}

# ========================================================================
# Batch fetch — one Docker call to download ALL deps at once
# ========================================================================

batch_fetch() {
  local dep_list="$1" fetch_dir="$2" source_format="$3"

  # Single Docker call, parallel per-package downloads (one failure doesn't block others)
  local MAX_DL=16
  case "$source_format" in
    deb)
      docker run --rm --platform "$PLATFORM" -v "$fetch_dir:/out" "$SOURCE_IMAGE" \
        bash -c "
          apt-get update -qq >/dev/null 2>&1
          cd /tmp
          for pkg in $dep_list; do
            (apt-get download \"\$pkg\" 2>/dev/null || true) &
            while [ \$(jobs -rp | wc -l) -ge $MAX_DL ]; do sleep 0.1; done
          done
          wait
          mv /tmp/*.deb /out/ 2>/dev/null || true
        " 2>/dev/null || true
      ;;
    rpm)
      docker run --rm --platform "$PLATFORM" -v "$fetch_dir:/out" "$SOURCE_IMAGE" \
        bash -c "
          for pkg in $dep_list; do
            (dnf download --destdir=/out \"\$pkg\" 2>/dev/null || true) &
            while [ \$(jobs -rp | wc -l) -ge $MAX_DL ]; do sleep 0.1; done
          done
          wait
        " 2>/dev/null || true
      ;;
    pacman)
      # pacman uses a db lock — no parallel, but try batch first for speed
      docker run --rm --platform "$PLATFORM" -v "$fetch_dir:/out" "$SOURCE_IMAGE" \
        bash -c "
          pacman -Sy --noconfirm >/dev/null 2>&1
          pacman -Sw --noconfirm $dep_list 2>/dev/null || {
            for pkg in $dep_list; do
              pacman -Sw --noconfirm \"\$pkg\" 2>/dev/null || true
            done
          }
          cp /var/cache/pacman/pkg/*.pkg.tar.* /out/ 2>/dev/null || true
        " 2>/dev/null || true
      ;;
  esac
}

# ========================================================================
# Parallel prefix + rebuild of fetched packages
# Each subprocess writes its mapping and sub-deps to individual files
# ========================================================================

prefix_and_rebuild() {
  local pkg_file="$1" result_dir="$2"

  mkdir -p "$result_dir"

  local int_dir
  int_dir=$(mktemp -d)

  if ! "$SCRIPT_DIR/pkg-extract.sh" "$pkg_file" "$int_dir" --source-distro "$SOURCE_DISTRO" >&2; then
    log_fail "extract $(basename "$pkg_file")"
    rm -rf "$int_dir"
    return 1
  fi

  local orig_name
  orig_name=$(cat "$int_dir/meta/name")
  local prefix="${DEP_PREFIX:-$SOURCE_DISTRO}"
  local prefixed="${prefix}-${orig_name}"

  # Skip if a compatible version already exists in the repo
  local pkg_version
  pkg_version=$(cat "$int_dir/meta/version")
  if dep_version_in_repo "$prefixed" "$pkg_version"; then
    echo "  [SKIP] $prefixed — compatible version already in repo" >&2
    echo "${orig_name}=${prefixed}" > "$result_dir/mapping"
    cat "$int_dir/meta/depends" > "$result_dir/subdeps" 2>/dev/null || touch "$result_dir/subdeps"
    rm -rf "$int_dir"
    return 0
  fi

  echo "$prefixed" > "$int_dir/meta/name"
  echo "$orig_name" >> "$int_dir/meta/provides"

  case "$TARGET_FORMAT" in
    deb)
      "$SCRIPT_DIR/pkg-build-deb.sh" "$int_dir" "$OUTPUT_DIR/" --dep-map "$DEP_MAP" >&2 || \
        log_fail "rebuild $prefixed (deb)" ;;
    rpm)
      "$SCRIPT_DIR/pkg-build-rpm.sh" "$int_dir" "$OUTPUT_DIR/" --dep-map "$DEP_MAP" >&2 || \
        log_fail "rebuild $prefixed (rpm)" ;;
    pacman)
      "$SCRIPT_DIR/pkg-build-pacman.sh" "$int_dir" "$OUTPUT_DIR/" --dep-map "$DEP_MAP" >&2 || \
        log_fail "rebuild $prefixed (pacman)" ;;
  esac

  echo "  -> Prefixed: $prefixed (provides $orig_name)" >&2

  # Write results to individual files (no shared state)
  echo "${orig_name}=${prefixed}" > "$result_dir/mapping"
  cat "$int_dir/meta/depends" > "$result_dir/subdeps" 2>/dev/null || touch "$result_dir/subdeps"

  rm -rf "$int_dir"
}

# ========================================================================
# Main
# ========================================================================

PLATFORM=$(get_platform)
TARGET_IMAGE=$(get_docker_image "$TARGET_DISTRO")
SOURCE_IMAGE=$(get_docker_image "${SOURCE_DISTRO:-noble}")
SOURCE_FORMAT=$(get_source_format)

declare -A CHECKED_DEPS

echo "=== Dependency Resolution ==="
echo "Source: $SOURCE_DISTRO ($SOURCE_FORMAT)"
echo "Target: $TARGET_DISTRO ($TARGET_FORMAT)"
echo "Arch: $ARCH"
echo ""

# Collect all deps from our built packages (already in TARGET_FORMAT naming)
initial_deps=""
for pkg_file in "$SOURCE_PKGS"/*; do
  [[ -f "$pkg_file" ]] || continue
  case "$pkg_file" in
    *.deb|*.rpm|*.pkg.tar.zst|*.pkg.tar.xz|*.pkg.tar.gz) ;;
    *) continue ;;
  esac
  echo "Scanning: $(basename "$pkg_file")"
  pkg_deps=$(collect_deps_from_pkg "$pkg_file")
  initial_deps="$initial_deps $pkg_deps"
done

# to_check is always in TARGET_FORMAT naming
to_check=$(echo "$initial_deps" | tr ' ' '\n' | sort -u | tr '\n' ' ')

total_fetched=0
round=0
while [[ -n "$(echo "$to_check" | xargs)" ]]; do
  round=$((round + 1))

  # Filter already checked + skip our own packages
  new_deps=""
  for dep in $to_check; do
    [[ -z "$dep" ]] && continue
    [[ -n "${SKIP_SET[$dep]+x}" ]] && continue
    if [[ -z "${CHECKED_DEPS[$dep]+x}" ]]; then
      new_deps="$new_deps $dep"
      CHECKED_DEPS["$dep"]=1
    fi
  done
  new_deps=$(echo "$new_deps" | xargs)
  [[ -z "$new_deps" ]] && break

  dep_count=$(echo "$new_deps" | wc -w)
  echo ""
  echo "--- Round $round: checking $dep_count deps in $TARGET_DISTRO ---"

  # Batch query target
  declare -A TGT_VERS=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="${line%%=*}"
    ver="${line#*=}"
    TGT_VERS["$name"]="$ver"
  done <<< "$(batch_get_versions "$new_deps" "$TARGET_IMAGE" "$TARGET_FORMAT")"

  # Separate missing from existing
  existing_deps=""
  missing_deps=""
  for dep in $new_deps; do
    if [[ "${TGT_VERS[$dep]:-MISSING}" == "MISSING" ]]; then
      missing_deps="$missing_deps $dep"
      echo "  [MISSING] $dep"
    else
      existing_deps="$existing_deps $dep"
    fi
  done
  existing_deps=$(echo "$existing_deps" | xargs)
  missing_deps=$(echo "$missing_deps" | xargs)

  # Compare versions for existing deps
  incompatible_deps=""
  declare -A TGT_TO_SRC=()
  declare -A SRC_VERS=()
  if [[ -n "$existing_deps" ]]; then
    # Map to source names
    source_query=""
    for dep in $existing_deps; do
      src_name=$(map_dep_name "$dep" "$TARGET_FORMAT" "$SOURCE_FORMAT")
      source_query="$source_query $src_name"
      TGT_TO_SRC["$dep"]="$src_name"
    done
    source_query=$(echo "$source_query" | xargs)

    # Batch query source
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      name="${line%%=*}"
      ver="${line#*=}"
      SRC_VERS["$name"]="$ver"
    done <<< "$(batch_get_versions "$source_query" "$SOURCE_IMAGE" "$SOURCE_FORMAT")"

    # Compare major.minor.patch
    for dep in $existing_deps; do
      src_name="${TGT_TO_SRC[$dep]}"
      src_ver="${SRC_VERS[$src_name]:-MISSING}"
      tgt_ver="${TGT_VERS[$dep]}"

      if [[ "$src_ver" == "MISSING" ]]; then
        echo "  [OK] $dep=$tgt_ver (not in source, using target)"
      elif versions_compatible "$src_ver" "$tgt_ver"; then
        echo "  [OK] $dep: $(parse_version_pair "$src_ver") = $(parse_version_pair "$tgt_ver")"
      else
        echo "  [MISMATCH] $dep: source=$(parse_version_pair "$src_ver") target=$(parse_version_pair "$tgt_ver")"
        incompatible_deps="$incompatible_deps $dep"
      fi
    done
  fi
  incompatible_deps=$(echo "$incompatible_deps" | xargs)

  # Determine what to fetch
  to_fetch="$missing_deps $incompatible_deps"
  to_fetch=$(echo "$to_fetch" | xargs)
  [[ -z "$to_fetch" ]] && { to_check=""; continue; }

  # Pre-skip: deps already prefixed in repo (from a prior device/run) don't need fetching
  actually_needed=""
  prefix="${DEP_PREFIX:-$SOURCE_DISTRO}"
  for dep in $to_fetch; do
    src_dep=$(map_dep_name "$dep" "$TARGET_FORMAT" "$SOURCE_FORMAT")
    prefixed="${prefix}-${src_dep}"
    src_ver="${SRC_VERS[$src_dep]:-${TGT_VERS[$dep]:-}}"
    if [[ -n "$src_ver" && "$src_ver" != "MISSING" ]] && dep_version_in_repo "$prefixed" "$src_ver"; then
      echo "  [PRE-SKIP] $prefixed — already in shared repo"
      echo "${dep}=${prefixed}" >> "$OUTPUT_DIR/dep-mapping.txt"
      total_fetched=$((total_fetched + 1))
    else
      actually_needed="$actually_needed $dep"
    fi
  done
  to_fetch=$(echo "$actually_needed" | xargs)
  [[ -z "$to_fetch" ]] && { to_check=""; continue; }

  # Map to source names for fetching
  src_fetch_list=""
  for dep in $to_fetch; do
    src_dep=$(map_dep_name "$dep" "$TARGET_FORMAT" "$SOURCE_FORMAT")
    src_fetch_list="$src_fetch_list $src_dep"
  done
  src_fetch_list=$(echo "$src_fetch_list" | xargs)

  # Check cache for already-fetched source packages
  if [[ -n "$CACHE_DIR" ]]; then
    remaining_fetch=""
    cached_count=0
    FETCH_DIR=$(mktemp -d)
    for src_dep in $src_fetch_list; do
      cached_file=$(ls "$CACHE_DIR"/${src_dep}_*.deb "$CACHE_DIR"/${src_dep}-[0-9]*.rpm "$CACHE_DIR"/${src_dep}-[0-9]*.pkg.tar.* 2>/dev/null | head -1) || true
      if [[ -n "$cached_file" && -f "$cached_file" ]]; then
        cp "$cached_file" "$FETCH_DIR/"
        cached_count=$((cached_count + 1))
      else
        remaining_fetch="$remaining_fetch $src_dep"
      fi
    done
    src_fetch_list=$(echo "$remaining_fetch" | xargs)
    [[ $cached_count -gt 0 ]] && echo "  Cache hit: $cached_count packages, still need $(echo "$src_fetch_list" | wc -w)"
  else
    FETCH_DIR=$(mktemp -d)
  fi

  # Batch fetch: one Docker call for remaining deps
  if [[ -n "$src_fetch_list" ]]; then
    echo "  Batch fetching $(echo "$src_fetch_list" | wc -w) packages from $SOURCE_DISTRO..."
    batch_fetch "$src_fetch_list" "$FETCH_DIR" "$SOURCE_FORMAT"
  fi

  # Save fetched packages to cache
  if [[ -n "$CACHE_DIR" ]]; then
    for pkg_file in "$FETCH_DIR"/*; do
      [[ -f "$pkg_file" ]] || continue
      cp "$pkg_file" "$CACHE_DIR/" 2>/dev/null || true
    done
  fi

  # Filter oversized packages (GitHub rejects files > 100 MB)
  for pkg_file in "$FETCH_DIR"/*; do
    [[ -f "$pkg_file" ]] || continue
    pkg_size=$(stat -c%s "$pkg_file" 2>/dev/null || stat -f%z "$pkg_file")
    if (( pkg_size > MAX_PKG_SIZE )); then
      echo "  [SKIP] $(basename "$pkg_file") — too large ($(( pkg_size / 1024 / 1024 )) MB > $(( MAX_PKG_SIZE / 1024 / 1024 )) MB)" >&2
      rm -f "$pkg_file"
    fi
  done

  # Parallel prefix + rebuild
  RESULTS_DIR=$(mktemp -d)
  fetch_idx=0
  for pkg_file in "$FETCH_DIR"/*; do
    [[ -f "$pkg_file" ]] || continue
    limit_jobs
    prefix_and_rebuild "$pkg_file" "$RESULTS_DIR/result-${fetch_idx}" &
    fetch_idx=$((fetch_idx + 1))
  done
  wait

  # Merge results: mappings + sub-deps
  next_round=""
  for result in "$RESULTS_DIR"/result-*/; do
    [[ -d "$result" ]] || continue

    if [[ -f "$result/mapping" ]]; then
      cat "$result/mapping" >> "$OUTPUT_DIR/dep-mapping.txt"
      total_fetched=$((total_fetched + 1))
    fi

    if [[ -s "$result/subdeps" ]]; then
      while IFS= read -r subdep; do
        [[ -z "$subdep" ]] && continue
        tgt_subdep=$(map_dep_name "$subdep" "$SOURCE_FORMAT" "$TARGET_FORMAT")
        next_round="$next_round $tgt_subdep"
      done < "$result/subdeps"
    fi
  done

  rm -rf "$FETCH_DIR" "$RESULTS_DIR"
  to_check=$(echo "$next_round" | tr ' ' '\n' | sort -u | tr '\n' ' ')
done

# Deduplicate mapping
if [[ -f "$OUTPUT_DIR/dep-mapping.txt" ]]; then
  sort -u -o "$OUTPUT_DIR/dep-mapping.txt" "$OUTPUT_DIR/dep-mapping.txt"
fi

# Summary
echo ""
echo "=== Done: $total_fetched dependencies fetched and prefixed ==="

if [[ $total_fetched -gt 0 && -s "$OUTPUT_DIR/dep-mapping.txt" ]]; then
  echo "Mappings:"
  while IFS='=' read -r orig prefixed; do
    echo "  $orig -> $prefixed"
  done < "$OUTPUT_DIR/dep-mapping.txt"
fi

if [[ -s "$FAIL_LOG" ]]; then
  echo ""
  echo "========================================="
  echo "DEPENDENCY RESOLUTION FAILURES:"
  sort "$FAIL_LOG" | uniq -c | sort -rn
  echo "========================================="
fi
rm -f "$FAIL_LOG"
