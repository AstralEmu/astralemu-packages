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

# Deps are built by duckstation-deps job and cached in /deps
if ! ls /deps/lib/*.so* 1>/dev/null 2>&1; then
  echo "ERROR: /deps not populated — duckstation-deps job must run first" >&2
  exit 1
fi

# Link prebuilt deps where cmake expects them (dep/prebuilt/linux-{arch})
# DuckStationDependencies.cmake sets CMAKE_PREFIX_PATH to dep/prebuilt/{platform}
case "$DEVICE_ARCH" in
  amd64) DEPS_DIR="linux-x64" ;;
  arm64) DEPS_DIR="linux-arm64" ;;
esac
mkdir -p dep/prebuilt
ln -sfn /deps dep/prebuilt/"$DEPS_DIR"

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
