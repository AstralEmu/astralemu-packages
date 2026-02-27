#!/bin/bash
set -e

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=5G
ccache -z

# Clone or update source
if [[ ! -d /workspace/src-duck ]]; then
  git clone --recursive https://github.com/stenzek/duckstation.git /workspace/src-duck
fi

cd /workspace/src-duck
git fetch --unshallow 2>/dev/null || git fetch origin
git checkout "$COMMIT"
git submodule update --init --recursive

# Download prebuilt deps if not already cached in /deps
if ! ls /deps/lib/*.so* 1>/dev/null 2>&1; then
  DEPS_RELEASE="release-20260224"
  case "$DEVICE_ARCH" in
    amd64) DEPS_TARBALL="deps-linux-x64.tar.xz" ;;
    arm64) DEPS_TARBALL="deps-linux-cross-arm64.tar.xz" ;;
  esac
  DEPS_URL="https://github.com/duckstation/dependencies/releases/download/$DEPS_RELEASE/$DEPS_TARBALL"
  echo "Deps not cached, downloading: $DEPS_URL"
  curl -L -o /tmp/deps.tar.xz "$DEPS_URL"
  mkdir -p /deps
  tar xf /tmp/deps.tar.xz -C /deps
  SUBDIRS=(/deps/*/)
  if [[ ${#SUBDIRS[@]} -eq 1 ]] && [[ -d "${SUBDIRS[0]}lib" ]]; then
    mv "${SUBDIRS[0]}"* /deps/ 2>/dev/null || true
    mv "${SUBDIRS[0]}".* /deps/ 2>/dev/null || true
    rmdir "${SUBDIRS[0]}" 2>/dev/null || true
  fi
  rm -f /tmp/deps.tar.xz
fi

# Link prebuilt deps where cmake expects them (dep/prebuilt/linux-{arch})
# DuckStationDependencies.cmake sets CMAKE_PREFIX_PATH to dep/prebuilt/{platform}
case "$DEVICE_ARCH" in
  amd64) DEPS_DIR="linux-x64" ;;
  arm64) DEPS_DIR="linux-arm64" ;;
esac
mkdir -p dep/prebuilt
ln -sfn /deps dep/prebuilt/"$DEPS_DIR"

# Native ARM64: cross-compile deps don't include Qt6 host tools (moc, uic, rcc).
# cmake finds system Qt6CoreTools (6.4.2) which mismatches prebuilt Qt6 (6.10.2).
# Generate minimal cmake shims that import system tools with matching version.
# Can't copy system configs — they use _IMPORT_PREFIX (relative paths) which resolve
# wrong when placed under /deps.
if [[ "$DEVICE_ARCH" == "arm64" ]]; then
  _qt_find() { find /usr -name "$1" \( -path "*/qt6/*" -o -path "*/libexec/*" \) -type f 2>/dev/null | head -1; }
  _qt_shim() {
    local pkg=$1; shift
    local dir="/deps/lib/cmake/$pkg"
    mkdir -p "$dir"
    cat > "$dir/${pkg}ConfigVersion.cmake" << 'CVEOF'
set(PACKAGE_VERSION "6.10.2")
set(PACKAGE_VERSION_EXACT FALSE)
set(PACKAGE_VERSION_COMPATIBLE TRUE)
set(PACKAGE_VERSION_UNSUITABLE FALSE)
CVEOF
    local conf="$dir/${pkg}Config.cmake"
    echo "# Shim: import system Qt6 tools for native ARM64 build" > "$conf"
    while [[ $# -gt 0 ]]; do
      local target=$1 bin=$2; shift 2
      local loc; loc=$(_qt_find "$bin")
      [[ -z "$loc" ]] && loc=$(which "$bin" 2>/dev/null)
      if [[ -n "$loc" ]]; then
        cat >> "$conf" << TEOF
if(NOT TARGET ${target})
  add_executable(${target} IMPORTED)
  set_target_properties(${target} PROPERTIES IMPORTED_LOCATION "${loc}")
endif()
TEOF
      fi
    done
  }
  _qt_shim Qt6CoreTools       Qt6::moc moc   Qt6::rcc rcc
  _qt_shim Qt6WidgetsTools    Qt6::uic uic
  _qt_shim Qt6DBusTools       Qt6::qdbuscpp2xml qdbuscpp2xml   Qt6::qdbusxml2cpp qdbusxml2cpp
  _qt_shim Qt6LinguistTools   Qt6::lrelease lrelease   Qt6::lupdate lupdate   Qt6::lconvert lconvert
fi

mkdir -p build && cd build

if [[ ! -f build.ninja ]]; then
  cmake .. -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_EXE_LINKER_FLAGS_INIT="-fuse-ld=lld -ljemalloc" \
    -DCMAKE_MODULE_LINKER_FLAGS_INIT="-fuse-ld=lld" \
    -DCMAKE_SHARED_LINKER_FLAGS_INIT="-fuse-ld=lld -ljemalloc" \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_C_FLAGS="$DEVICE_CFLAGS -flto=thin" \
    -DCMAKE_CXX_FLAGS="$DEVICE_CXXFLAGS -flto=thin" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DENABLE_WAYLAND=OFF \
    -DENABLE_X11=ON
fi

ninja -j$(nproc)

# DuckStation has no install target, copy manually
mkdir -p /tmp/pkg/root/usr/bin /tmp/pkg/root/usr/lib/duckstation /tmp/pkg/root/usr/share/applications

cp bin/duckstation-qt /tmp/pkg/root/usr/bin/
cp -r bin/resources /tmp/pkg/root/usr/lib/duckstation/ 2>/dev/null || true

# Bundle the custom-built libraries
cp /deps/lib/*.so* /tmp/pkg/root/usr/lib/duckstation/ 2>/dev/null || true

# Set rpath for bundled libs
patchelf --set-rpath /usr/lib/duckstation /tmp/pkg/root/usr/bin/duckstation-qt 2>/dev/null || true

cat > /tmp/pkg/root/usr/share/applications/duckstation.desktop << DESK
[Desktop Entry]
Name=DuckStation
Comment=PlayStation 1 Emulator
Exec=duckstation-qt
Icon=duckstation
Terminal=false
Type=Application
Categories=Game;Emulator;
DESK

PKG_VERSION="0.0.0+git.${SHORT}"
mkdir -p /tmp/pkg/meta
echo "duckstation-${DEVICE_ID}" > /tmp/pkg/meta/name
echo "${PKG_VERSION}" > /tmp/pkg/meta/version
echo "${DEVICE_ARCH}" > /tmp/pkg/meta/arch
echo "DuckStation PS1 Emulator (${DEVICE_ID} build) - Includes bundled Qt6, SDL3 and other libraries." > /tmp/pkg/meta/description
echo "AstralEmu <noreply@astralemu.github.io>" > /tmp/pkg/meta/maintainer
echo "deb" > /tmp/pkg/meta/source_format
echo "noble" > /tmp/pkg/meta/source_distro
echo "games" > /tmp/pkg/meta/section
echo "optional" > /tmp/pkg/meta/priority
cat > /tmp/pkg/meta/depends << DEPS
libc6
libjemalloc2
libdbus-1-3
libcurl4t64
libwayland-client0
libudev1
DEPS
tar cf /workspace/duckstation-${DEVICE_ID}_${PKG_VERSION}_${DEVICE_ARCH}.pkg.tar -C /tmp/pkg meta root

ccache -s
