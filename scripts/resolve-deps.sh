#!/bin/bash
# resolve-deps.sh — Recursive dependency resolution across distros
#
# For each source package, checks if its dependencies exist in the target distro.
# Missing deps are fetched from the source distro, prefixed with source codename,
# and recursively resolved.
#
# Usage:
#   ./resolve-deps.sh --source-pkgs <dir-with-packages> \
#                     --source-distro <codename> \
#                     --target-distro <codename> \
#                     --target-format <deb|rpm|pacman> \
#                     --distros-config <distros.yml> \
#                     --dep-map <dep-map.conf> \
#                     --output-dir <dir-for-fetched-deps> \
#                     --arch <aarch64|x86_64>
set -euo pipefail

SOURCE_PKGS=""
SOURCE_DISTRO=""
TARGET_DISTRO=""
TARGET_FORMAT=""
DISTROS_CONFIG=""
DEP_MAP=""
OUTPUT_DIR=""
ARCH="aarch64"

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
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$SOURCE_PKGS" || -z "$TARGET_DISTRO" || -z "$TARGET_FORMAT" || -z "$OUTPUT_DIR" ]]; then
  echo "ERROR: Missing required arguments" >&2
  echo "Usage: $0 --source-pkgs <dir> --target-distro <codename> --target-format <deb|rpm|pacman> --output-dir <dir> [options]" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Map deb arch conventions
deb_arch() {
  case "$1" in
    aarch64) echo "arm64" ;;
    x86_64)  echo "amd64" ;;
    *)       echo "$1" ;;
  esac
}

DEB_ARCH=$(deb_arch "$ARCH")

# Determine Docker image for target distro
get_docker_image() {
  local distro="$1"
  case "$distro" in
    noble)    echo "ubuntu:24.04" ;;
    trixie)   echo "debian:trixie" ;;
    fedora41) echo "fedora:41" ;;
    arch)     echo "archlinux:latest" ;;
    *)        echo "ubuntu:24.04" ;;
  esac
}

# Determine Docker image for source distro
get_source_docker_image() {
  local distro="$1"
  case "$distro" in
    noble)    echo "ubuntu:24.04" ;;
    trixie)   echo "debian:trixie" ;;
    fedora41) echo "fedora:41" ;;
    arch)     echo "archlinux:latest" ;;
    *)        echo "ubuntu:24.04" ;;
  esac
}

# Determine platform from arch
get_platform() {
  case "$ARCH" in
    aarch64) echo "linux/arm64" ;;
    x86_64)  echo "linux/amd64" ;;
    *)       echo "linux/arm64" ;;
  esac
}

PLATFORM=$(get_platform)
TARGET_IMAGE=$(get_docker_image "$TARGET_DISTRO")
SOURCE_IMAGE=$(get_source_docker_image "${SOURCE_DISTRO:-noble}")

# Track already-checked deps to avoid infinite recursion
declare -A CHECKED_DEPS
declare -A FETCHED_DEPS

# Map dep name from source format to target format
map_dep_name() {
  local dep="$1"
  local from_format="$2"
  local to_format="$3"

  # Same format, no mapping
  if [[ "$from_format" == "$to_format" ]]; then
    echo "$dep"
    return
  fi

  if [[ -z "$DEP_MAP" || ! -f "$DEP_MAP" ]]; then
    echo "$dep"
    return
  fi

  local mapped=""
  case "${from_format}:${to_format}" in
    deb:rpm)
      mapped=$(grep "^${dep} " "$DEP_MAP" | head -1 | grep -oP 'rpm:\K[^,\s]+' | tr -d ' ')
      ;;
    deb:pacman)
      mapped=$(grep "^${dep} " "$DEP_MAP" | head -1 | grep -oP 'pac:\K[^,\s]+' | tr -d ' ')
      ;;
    rpm:deb)
      mapped=$(grep "rpm:${dep}" "$DEP_MAP" | head -1 | cut -d'=' -f1 | tr -d ' ')
      ;;
    rpm:pacman)
      mapped=$(grep "rpm:${dep}" "$DEP_MAP" | head -1 | grep -oP 'pac:\K[^,\s]+' | tr -d ' ')
      ;;
    pacman:deb)
      mapped=$(grep "pac:${dep}" "$DEP_MAP" | head -1 | cut -d'=' -f1 | tr -d ' ')
      ;;
    pacman:rpm)
      mapped=$(grep "pac:${dep}" "$DEP_MAP" | head -1 | grep -oP 'rpm:\K[^,\s]+' | tr -d ' ')
      ;;
  esac

  echo "${mapped:-$dep}"
}

# Check if a package exists in the target distro
check_dep_exists_in_target() {
  local dep_name="$1"

  case "$TARGET_FORMAT" in
    deb)
      docker run --rm --platform "$PLATFORM" "$TARGET_IMAGE" \
        bash -c "apt-get update -qq 2>/dev/null && apt-cache show '$dep_name' 2>/dev/null | head -1" 2>/dev/null | grep -q "Package:" && return 0
      ;;
    rpm)
      docker run --rm --platform "$PLATFORM" "$TARGET_IMAGE" \
        bash -c "dnf repoquery '$dep_name' 2>/dev/null" 2>/dev/null | grep -q . && return 0
      ;;
    pacman)
      docker run --rm --platform "$PLATFORM" "$TARGET_IMAGE" \
        bash -c "pacman -Sy --noconfirm 2>/dev/null && pacman -Ss '^${dep_name}$' 2>/dev/null" 2>/dev/null | grep -q . && return 0
      ;;
  esac

  return 1
}

# Fetch a dependency from the source distro
fetch_dep_from_source() {
  local dep_name="$1"
  local source_format="$2"

  echo "  Fetching $dep_name from $SOURCE_DISTRO..."

  local fetch_dir
  fetch_dir=$(mktemp -d)

  case "$source_format" in
    deb)
      docker run --rm --platform "$PLATFORM" \
        -v "$fetch_dir:/out" \
        "$SOURCE_IMAGE" \
        bash -c "
          apt-get update -qq 2>/dev/null
          cd /tmp
          apt-get download '$dep_name' 2>/dev/null
          cp *.deb /out/ 2>/dev/null
        "
      ;;
    rpm)
      docker run --rm --platform "$PLATFORM" \
        -v "$fetch_dir:/out" \
        "$SOURCE_IMAGE" \
        bash -c "
          dnf download --destdir=/out '$dep_name' 2>/dev/null
        "
      ;;
    pacman)
      docker run --rm --platform "$PLATFORM" \
        -v "$fetch_dir:/out" \
        "$SOURCE_IMAGE" \
        bash -c "
          pacman -Sy --noconfirm 2>/dev/null
          pacman -Sw --noconfirm '$dep_name' 2>/dev/null
          cp /var/cache/pacman/pkg/${dep_name}-*.pkg.tar.* /out/ 2>/dev/null
        "
      ;;
  esac

  # Rename with source distro prefix and move to output
  for pkg_file in "$fetch_dir"/*; do
    if [[ -f "$pkg_file" ]]; then
      local base
      base=$(basename "$pkg_file")
      local prefixed="${SOURCE_DISTRO}-${base}"
      cp "$pkg_file" "$OUTPUT_DIR/$prefixed"
      echo "  -> Fetched: $prefixed"
      FETCHED_DEPS["$dep_name"]="$prefixed"

      # Recurse: extract this fetched dep and check its deps too
      resolve_deps_for_package "$OUTPUT_DIR/$prefixed" "$source_format"
    fi
  done

  rm -rf "$fetch_dir"
}

# Determine source format from source distro
get_source_format() {
  case "${SOURCE_DISTRO:-noble}" in
    noble|trixie) echo "deb" ;;
    fedora41)     echo "rpm" ;;
    arch)         echo "pacman" ;;
    *)            echo "deb" ;;
  esac
}

SOURCE_FORMAT=$(get_source_format)

# Resolve dependencies for a single package file
resolve_deps_for_package() {
  local pkg_file="$1"
  local pkg_format="$2"

  local deps_list=""

  case "$pkg_format" in
    deb)
      deps_list=$(dpkg-deb -f "$pkg_file" Depends 2>/dev/null | tr ',' '\n' | \
        sed 's/([^)]*)//g; s/|.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)
      ;;
    rpm)
      deps_list=$(rpm -qp --requires "$pkg_file" 2>/dev/null | grep -v '^rpmlib(' | grep -v '^/' | \
        sed 's/[[:space:]]*[><=].*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u || true)
      ;;
    pacman)
      local tmpext
      tmpext=$(mktemp -d)
      tar xf "$pkg_file" -C "$tmpext" .PKGINFO 2>/dev/null || true
      if [[ -f "$tmpext/.PKGINFO" ]]; then
        deps_list=$(grep '^depend = ' "$tmpext/.PKGINFO" | sed 's/^depend = //' | \
          sed 's/[><=].*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true)
      fi
      rm -rf "$tmpext"
      ;;
  esac

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue

    # Map to target format name for checking
    local target_dep
    target_dep=$(map_dep_name "$dep" "$pkg_format" "$TARGET_FORMAT")

    # Skip if already checked
    if [[ -n "${CHECKED_DEPS[$target_dep]+x}" ]]; then
      continue
    fi
    CHECKED_DEPS["$target_dep"]=1

    # Check if exists in target distro
    if check_dep_exists_in_target "$target_dep"; then
      echo "  [OK] $target_dep exists in $TARGET_DISTRO"
    else
      echo "  [MISSING] $target_dep not in $TARGET_DISTRO, fetching from $SOURCE_DISTRO..."
      # Map back to source format name to fetch
      local source_dep
      source_dep=$(map_dep_name "$target_dep" "$TARGET_FORMAT" "$SOURCE_FORMAT")
      fetch_dep_from_source "$source_dep" "$SOURCE_FORMAT"
    fi
  done <<< "$deps_list"
}

echo "=== Dependency Resolution ==="
echo "Source: $SOURCE_DISTRO ($SOURCE_FORMAT)"
echo "Target: $TARGET_DISTRO ($TARGET_FORMAT)"
echo "Arch: $ARCH"
echo ""

# Process each source package
for pkg_file in "$SOURCE_PKGS"/*; do
  if [[ ! -f "$pkg_file" ]]; then
    continue
  fi

  # Detect format
  case "$pkg_file" in
    *.deb)                              pkg_format="deb" ;;
    *.rpm)                              pkg_format="rpm" ;;
    *.pkg.tar.zst|*.pkg.tar.xz|*.pkg.tar.gz) pkg_format="pacman" ;;
    *) continue ;;
  esac

  echo "Resolving deps for: $(basename "$pkg_file")"
  resolve_deps_for_package "$pkg_file" "$pkg_format"
  echo ""
done

TOTAL_FETCHED=${#FETCHED_DEPS[@]}
echo "=== Done: $TOTAL_FETCHED dependencies fetched ==="

if [[ $TOTAL_FETCHED -gt 0 ]]; then
  echo "Fetched packages:"
  for dep in "${!FETCHED_DEPS[@]}"; do
    echo "  $dep -> ${FETCHED_DEPS[$dep]}"
  done
fi
