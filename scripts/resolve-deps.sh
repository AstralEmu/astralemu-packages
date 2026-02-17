#!/bin/bash
# resolve-deps.sh — Recursive dependency resolution across distros
#
# Checks if dependencies exist in the target distro with compatible versions
# (same major.minor.patch — bugfix/revision differences are ignored).
# Missing or incompatible deps are fetched from source, rebuilt with a prefixed
# Package name (e.g. noble-libfoo) and Provides: original_name.
#
# Outputs:
#   - Rebuilt prefixed packages in OUTPUT_DIR/
#   - dep-mapping.txt in OUTPUT_DIR/ (original=prefixed, one per line)
#
# Uses batched Docker calls (2 per resolution round) for efficiency.
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
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
> "$OUTPUT_DIR/dep-mapping.txt"

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

# Extract major.minor.patch, ignore bugfix/revision
parse_version_triple() {
  local ver="$1"
  ver="${ver#*:}"                          # strip epoch
  ver="${ver%%-*}"                         # strip revision
  ver=$(echo "$ver" | sed 's/[+~].*//')   # strip modifiers
  local IFS='.'
  read -ra parts <<< "$ver"
  echo "${parts[0]:-0}.${parts[1]:-0}.${parts[2]:-0}"
}

versions_compatible() {
  [[ "$(parse_version_triple "$1")" == "$(parse_version_triple "$2")" ]]
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
        for pkg in $dep_list; do
          ver=\$(apt-cache show \"\$pkg\" 2>/dev/null | grep '^Version:' | head -1 | sed 's/^Version: //')
          if [ -n \"\$ver\" ]; then echo \"\${pkg}=\${ver}\"; else echo \"\${pkg}=MISSING\"; fi
        done
      " 2>/dev/null || true
      ;;
    rpm)
      docker run --rm --platform "$PLATFORM" "$image" bash -c "
        for pkg in $dep_list; do
          ver=\$(dnf repoquery --qf '%{version}-%{release}' \"\$pkg\" 2>/dev/null | head -1)
          if [ -n \"\$ver\" ]; then echo \"\${pkg}=\${ver}\"; else echo \"\${pkg}=MISSING\"; fi
        done
      " 2>/dev/null || true
      ;;
    pacman)
      docker run --rm --platform "$PLATFORM" "$image" bash -c "
        pacman -Sy --noconfirm >/dev/null 2>&1
        for pkg in $dep_list; do
          ver=\$(pacman -Si \"\$pkg\" 2>/dev/null | grep '^Version' | head -1 | sed 's/.*: //')
          if [ -n \"\$ver\" ]; then echo \"\${pkg}=\${ver}\"; else echo \"\${pkg}=MISSING\"; fi
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
        sed 's/([^)]*)//g; s/|.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
      ;;
    *.rpm)
      rpm -qp --requires "$pkg_file" 2>/dev/null | grep -v '^rpmlib(' | grep -v '^/' | \
        sed 's/[[:space:]]*[><=].*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sort -u || true
      ;;
    *.pkg.tar.zst|*.pkg.tar.xz|*.pkg.tar.gz)
      local tmpext
      tmpext=$(mktemp -d)
      tar xf "$pkg_file" -C "$tmpext" .PKGINFO 2>/dev/null || true
      if [[ -f "$tmpext/.PKGINFO" ]]; then
        grep '^depend = ' "$tmpext/.PKGINFO" | sed 's/^depend = //; s/[><=].*//' | \
          sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' || true
      fi
      rm -rf "$tmpext"
      ;;
  esac
}

# ========================================================================
# Fetch a dep from source, prefix, rebuild as target format
# Prints sub-deps (in SOURCE_FORMAT) on stdout for recursion
# ========================================================================

fetch_and_prefix() {
  local dep_name="$1" source_format="$2"

  echo "  Fetching $dep_name from $SOURCE_DISTRO..." >&2

  local fetch_dir
  fetch_dir=$(mktemp -d)

  case "$source_format" in
    deb)
      docker run --rm --platform "$PLATFORM" -v "$fetch_dir:/out" "$SOURCE_IMAGE" \
        bash -c "
          apt-get update -qq >/dev/null 2>&1
          cd /tmp && apt-get download '$dep_name' 2>/dev/null
          cp *.deb /out/ 2>/dev/null
        " 2>/dev/null || true
      ;;
    rpm)
      docker run --rm --platform "$PLATFORM" -v "$fetch_dir:/out" "$SOURCE_IMAGE" \
        bash -c "dnf download --destdir=/out '$dep_name' 2>/dev/null" 2>/dev/null || true
      ;;
    pacman)
      docker run --rm --platform "$PLATFORM" -v "$fetch_dir:/out" "$SOURCE_IMAGE" \
        bash -c "
          pacman -Sy --noconfirm >/dev/null 2>&1
          pacman -Sw --noconfirm '$dep_name' 2>/dev/null
          cp /var/cache/pacman/pkg/${dep_name}-*.pkg.tar.* /out/ 2>/dev/null
        " 2>/dev/null || true
      ;;
  esac

  for pkg_file in "$fetch_dir"/*; do
    [[ -f "$pkg_file" ]] || continue

    # Extract to intermediate
    local int_dir
    int_dir=$(mktemp -d)
    if ! "$SCRIPT_DIR/pkg-extract.sh" "$pkg_file" "$int_dir" --source-distro "$SOURCE_DISTRO" >&2; then
      echo "  WARNING: Failed to extract $(basename "$pkg_file")" >&2
      rm -rf "$int_dir"
      continue
    fi

    # Prefix Package name
    local orig_name
    orig_name=$(cat "$int_dir/meta/name")
    local prefixed="${SOURCE_DISTRO}-${orig_name}"
    echo "$prefixed" > "$int_dir/meta/name"

    # Add Provides so original name resolves
    echo "$orig_name" >> "$int_dir/meta/provides"

    # Rebuild as target format
    case "$TARGET_FORMAT" in
      deb)
        "$SCRIPT_DIR/pkg-build-deb.sh" "$int_dir" "$OUTPUT_DIR/" --dep-map "$DEP_MAP" >&2 || \
          echo "  WARNING: Failed to rebuild $prefixed as deb" >&2 ;;
      rpm)
        "$SCRIPT_DIR/pkg-build-rpm.sh" "$int_dir" "$OUTPUT_DIR/" --dep-map "$DEP_MAP" >&2 || \
          echo "  WARNING: Failed to rebuild $prefixed as rpm" >&2 ;;
      pacman)
        "$SCRIPT_DIR/pkg-build-pacman.sh" "$int_dir" "$OUTPUT_DIR/" --dep-map "$DEP_MAP" >&2 || \
          echo "  WARNING: Failed to rebuild $prefixed as pacman" >&2 ;;
    esac

    echo "  -> Prefixed: $prefixed (provides $orig_name)" >&2
    FETCHED_DEPS["$dep_name"]="$prefixed"

    # Record mapping
    echo "${orig_name}=${prefixed}" >> "$OUTPUT_DIR/dep-mapping.txt"

    # Output sub-deps for recursion (in source format, via stdout)
    if [[ -f "$int_dir/meta/depends" ]]; then
      cat "$int_dir/meta/depends"
    fi

    rm -rf "$int_dir"
  done

  rm -rf "$fetch_dir"
}

# ========================================================================
# Main
# ========================================================================

PLATFORM=$(get_platform)
TARGET_IMAGE=$(get_docker_image "$TARGET_DISTRO")
SOURCE_IMAGE=$(get_docker_image "${SOURCE_DISTRO:-noble}")
SOURCE_FORMAT=$(get_source_format)

declare -A CHECKED_DEPS
declare -A FETCHED_DEPS

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

round=0
while [[ -n "$(echo "$to_check" | xargs)" ]]; do
  round=$((round + 1))

  # Filter already checked
  new_deps=""
  for dep in $to_check; do
    [[ -z "$dep" ]] && continue
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
  if [[ -n "$existing_deps" ]]; then
    # Map to source names
    source_query=""
    declare -A TGT_TO_SRC=()
    for dep in $existing_deps; do
      src_name=$(map_dep_name "$dep" "$TARGET_FORMAT" "$SOURCE_FORMAT")
      source_query="$source_query $src_name"
      TGT_TO_SRC["$dep"]="$src_name"
    done
    source_query=$(echo "$source_query" | xargs)

    # Batch query source
    declare -A SRC_VERS=()
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
        echo "  [OK] $dep: $(parse_version_triple "$src_ver") = $(parse_version_triple "$tgt_ver")"
      else
        echo "  [MISMATCH] $dep: source=$(parse_version_triple "$src_ver") target=$(parse_version_triple "$tgt_ver")"
        incompatible_deps="$incompatible_deps $dep"
      fi
    done
  fi
  incompatible_deps=$(echo "$incompatible_deps" | xargs)

  # Fetch missing + incompatible
  to_fetch="$missing_deps $incompatible_deps"
  to_fetch=$(echo "$to_fetch" | xargs)

  next_round=""
  for dep in $to_fetch; do
    [[ -z "$dep" ]] && continue
    src_dep=$(map_dep_name "$dep" "$TARGET_FORMAT" "$SOURCE_FORMAT")

    # fetch_and_prefix prints sub-deps (SOURCE_FORMAT) on stdout
    sub_deps=$(fetch_and_prefix "$src_dep" "$SOURCE_FORMAT")

    # Map sub-deps to TARGET_FORMAT for next round
    while IFS= read -r subdep; do
      [[ -z "$subdep" ]] && continue
      tgt_subdep=$(map_dep_name "$subdep" "$SOURCE_FORMAT" "$TARGET_FORMAT")
      next_round="$next_round $tgt_subdep"
    done <<< "$sub_deps"
  done

  to_check=$(echo "$next_round" | tr ' ' '\n' | sort -u | tr '\n' ' ')
done

# Deduplicate mapping
if [[ -f "$OUTPUT_DIR/dep-mapping.txt" ]]; then
  sort -u -o "$OUTPUT_DIR/dep-mapping.txt" "$OUTPUT_DIR/dep-mapping.txt"
fi

# Summary
TOTAL_FETCHED=${#FETCHED_DEPS[@]}
echo ""
echo "=== Done: $TOTAL_FETCHED dependencies fetched and prefixed ==="

if [[ $TOTAL_FETCHED -gt 0 ]]; then
  echo "Prefixed packages:"
  for dep in "${!FETCHED_DEPS[@]}"; do
    echo "  $dep -> ${FETCHED_DEPS[$dep]}"
  done
  echo ""
  echo "Mapping file: $OUTPUT_DIR/dep-mapping.txt"
fi
