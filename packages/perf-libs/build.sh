#!/bin/bash
# Build script for perf-libs — unified performance-critical system libraries
#
# Reads libraries.yml for dependency graph + per-distro provides.
# Resolves build order via topological sort on depends_on.
# Each sub-package in packages/<id>/build.sh handles its own build.
set -e

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=10G
ccache -z

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBS_YML="$SCRIPT_DIR/libraries.yml"

# Staging prefix — all libs install here, then get collected
export PREFIX="/opt/perf-libs-staging"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"

# Use clang — required for -flto=thin (gcc only supports -flto)
export CC=clang
export CXX=clang++

# Use lld — required for ThinLTO (ld.bfd doesn't support it)
export CC_LD=lld
export CXX_LD=lld
export LDFLAGS="-fuse-ld=lld"
export TARGET_LDFLAGS="-fuse-ld=lld"

export NPROC=$(nproc)

# Arch detection
export IS_X86=false IS_ARM=false
case "$TARGET_ARCH" in
  amd64|x86_64) IS_X86=true ;;
  arm64|aarch64) IS_ARM=true ;;
esac

# ============================================================
# Parse libraries.yml and resolve build order (topological sort)
# ============================================================
LIB_COUNT=$(yq '.libraries | length' "$LIBS_YML")

# Build adjacency list and filter by arch
declare -A LIB_DEPS
declare -a LIB_IDS=()

for (( i=0; i<LIB_COUNT; i++ )); do
  lib_id=$(yq -r ".libraries[$i].id" "$LIBS_YML")
  lib_arch=$(yq -r ".libraries[$i].arch // \"\"" "$LIBS_YML")

  # Skip if arch-restricted and doesn't match
  if [[ -n "$lib_arch" ]]; then
    case "$lib_arch" in
      x86) $IS_X86 || continue ;;
      arm) $IS_ARM || continue ;;
    esac
  fi

  LIB_IDS+=("$lib_id")
  deps=$(yq -r ".libraries[$i].depends_on // [] | .[]" "$LIBS_YML" 2>/dev/null || true)
  LIB_DEPS["$lib_id"]="$deps"
done

# Kahn's algorithm for topological sort
declare -A IN_DEGREE
declare -A ADJACENCY
for id in "${LIB_IDS[@]}"; do
  IN_DEGREE["$id"]=0
done
for id in "${LIB_IDS[@]}"; do
  for dep in ${LIB_DEPS[$id]}; do
    # Only count deps that are in our filtered list
    [[ -n "${IN_DEGREE[$dep]+x}" ]] || continue
    ADJACENCY["$dep"]+=" $id"
    IN_DEGREE["$id"]=$(( ${IN_DEGREE[$id]} + 1 ))
  done
done

QUEUE=()
for id in "${LIB_IDS[@]}"; do
  [[ ${IN_DEGREE[$id]} -eq 0 ]] && QUEUE+=("$id")
done

BUILD_ORDER=()
while [[ ${#QUEUE[@]} -gt 0 ]]; do
  current="${QUEUE[0]}"
  QUEUE=("${QUEUE[@]:1}")
  BUILD_ORDER+=("$current")
  for neighbor in ${ADJACENCY[$current]}; do
    IN_DEGREE["$neighbor"]=$(( ${IN_DEGREE[$neighbor]} - 1 ))
    [[ ${IN_DEGREE[$neighbor]} -eq 0 ]] && QUEUE+=("$neighbor")
  done
done

if [[ ${#BUILD_ORDER[@]} -ne ${#LIB_IDS[@]} ]]; then
  echo "ERROR: Circular dependency detected in libraries.yml" >&2
  exit 1
fi

echo "Build order: ${BUILD_ORDER[*]}"

# ============================================================
# Build each sub-package in resolved order
# ============================================================
for pkg_name in "${BUILD_ORDER[@]}"; do
  pkg_dir="$SCRIPT_DIR/packages/$pkg_name"

  if [[ ! -f "$pkg_dir/build.sh" ]]; then
    echo "WARN: no build.sh for $pkg_name, skipping"
    continue
  fi

  echo "============================================"
  echo "  Building: $pkg_name"
  echo "============================================"
  bash "$pkg_dir/build.sh"

  # Update search paths after each install
  export PKG_CONFIG_PATH="$PREFIX/usr/lib/pkgconfig:$PREFIX/usr/lib64/pkgconfig:$PREFIX/usr/share/pkgconfig:/usr/lib/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig"
  export CMAKE_PREFIX_PATH="$PREFIX/usr:/usr"
  export LD_LIBRARY_PATH="$PREFIX/usr/lib:$PREFIX/usr/lib64:/usr/lib:/usr/lib64"
done

# ============================================================
# Package everything
# ============================================================
echo "============================================"
echo "  Packaging perf-libs"
echo "============================================"

PKG_ROOT="/tmp/pkg/root"
rm -rf /tmp/pkg
mkdir -p "$PKG_ROOT" /tmp/pkg/meta

# Copy /usr from staging
cp -a "$PREFIX/usr" "$PKG_ROOT/"

# Strip binaries and libraries
find "$PKG_ROOT" -type f \( -name '*.so' -o -name '*.so.*' \) -exec strip --strip-unneeded {} \; 2>/dev/null || true
find "$PKG_ROOT" -type f -executable -exec file {} \; | grep -i 'elf' | cut -d: -f1 | xargs -r strip --strip-unneeded 2>/dev/null || true

# Remove development files
rm -rf "$PKG_ROOT/usr/include"
rm -rf "$PKG_ROOT/usr/share/man" "$PKG_ROOT/usr/share/doc"
find "$PKG_ROOT" -name '*.a' -delete 2>/dev/null || true
find "$PKG_ROOT" -name '*.la' -delete 2>/dev/null || true
rm -rf "$PKG_ROOT/usr/lib/pkgconfig" "$PKG_ROOT/usr/lib64/pkgconfig" "$PKG_ROOT/usr/share/pkgconfig"
rm -rf "$PKG_ROOT/usr/lib/cmake" "$PKG_ROOT/usr/lib64/cmake" "$PKG_ROOT/usr/share/cmake"

# Metadata — version suffix is the build hash short so the deb version
# bumps whenever build.sh / sub-builds / config change, otherwise
# pkg_exists_in_repo keeps the old deb on gh-pages.
VERSION="1.0.0+${SHORT:-0000000}"
echo "perf-libs-${TARGET_ID}" > /tmp/pkg/meta/name
echo "$VERSION" > /tmp/pkg/meta/version
echo "$TARGET_ARCH" > /tmp/pkg/meta/arch
echo "Performance-optimized system libraries for ${TARGET_ID}" > /tmp/pkg/meta/description
echo "AstralEmu <noreply@astralemu.github.io>" > /tmp/pkg/meta/maintainer
echo "deb" > /tmp/pkg/meta/source_format
echo "${SOURCE_DISTRO:-noble}" > /tmp/pkg/meta/source_distro
echo "libs" > /tmp/pkg/meta/section
echo "optional" > /tmp/pkg/meta/priority

cat > /tmp/pkg/meta/depends << 'DEPS'
libc6
libexpat1
libelf1
libffi8
libpciaccess0
libsensors5
libx11-6
libxcb1
libxext6
libxfixes3
libxshmfence1
libxxf86vm1
libwayland-client0
libwayland-server0
DEPS

# Generate per-distro provides/conflicts/replaces from libraries.yml
DISTROS=$(yq -r '.libraries[0].provides | keys | .[]' "$LIBS_YML")
for distro in $DISTROS; do
  : > "/tmp/pkg/meta/provides.${distro}"
  for (( i=0; i<LIB_COUNT; i++ )); do
    lib_id=$(yq -r ".libraries[$i].id" "$LIBS_YML")
    lib_arch=$(yq -r ".libraries[$i].arch // \"\"" "$LIBS_YML")

    # Skip if arch-restricted and doesn't match
    if [[ -n "$lib_arch" ]]; then
      case "$lib_arch" in
        x86) $IS_X86 || continue ;;
        arm) $IS_ARM || continue ;;
      esac
    fi

    yq -r ".libraries[$i].provides.${distro} // [] | .[]" "$LIBS_YML" >> "/tmp/pkg/meta/provides.${distro}"
  done

  # conflicts + replaces = same as provides
  cp "/tmp/pkg/meta/provides.${distro}" "/tmp/pkg/meta/conflicts.${distro}"
  cp "/tmp/pkg/meta/provides.${distro}" "/tmp/pkg/meta/replaces.${distro}"
done

# Append device-alias Provides/Replaces into each provides.<distro>/replaces.<distro>
bash /workspace/scripts/emit-aliases.sh perf-libs /tmp/pkg/meta

# Build intermediate tar
tar cf "/workspace/perf-libs-${TARGET_ID}_${VERSION}_${TARGET_ARCH}.pkg.tar" -C /tmp/pkg meta root

ccache -s
echo "completed" > /workspace/build-status
