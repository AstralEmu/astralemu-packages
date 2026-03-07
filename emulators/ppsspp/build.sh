#!/bin/bash
set -e

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=5G
ccache -z

if [[ ! -d /workspace/src-ppsspp ]]; then
  git clone https://github.com/hrydgard/ppsspp.git /workspace/src-ppsspp
fi

cd /workspace/src-ppsspp
git fetch origin --tags
git checkout "$VERSION"
git submodule update --init --recursive
mkdir -p build && cd build

if [[ ! -f build.ninja ]]; then
  cmake .. -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_C_FLAGS="$DEVICE_CFLAGS -flto" \
    -DCMAKE_CXX_FLAGS="$DEVICE_CXXFLAGS -flto" \
    -DCMAKE_EXE_LINKER_FLAGS="-ljemalloc" \
    -DCMAKE_SHARED_LINKER_FLAGS="-ljemalloc" \
    -DUSING_QT_UI=OFF \
    -DHEADLESS=OFF \
    -DUSE_WAYLAND_WSI=OFF \
    -DVULKAN=ON
fi

timeout ${BUILD_TIMEOUT}s ninja -j$(nproc) || {
  EXIT_CODE=$?
  ccache -s
  if [[ $EXIT_CODE -eq 124 ]]; then
    echo "timeout" > /workspace/build-status
    exit 0
  fi
  exit $EXIT_CODE
}

mkdir -p /tmp/pkg/root/usr/bin /tmp/pkg/root/usr/share/applications /tmp/pkg/root/usr/share/ppsspp
cp PPSSPPSDL /tmp/pkg/root/usr/bin/ppsspp
cp -r ../assets /tmp/pkg/root/usr/share/ppsspp/

cat > /tmp/pkg/root/usr/share/applications/ppsspp.desktop << DESK
[Desktop Entry]
Name=PPSSPP
Comment=PlayStation Portable Emulator
Exec=ppsspp
Icon=ppsspp
Terminal=false
Type=Application
Categories=Game;Emulator;
DESK

VERSION_CLEAN=$(echo "$VERSION" | sed "s/^v//")
mkdir -p /tmp/pkg/meta
echo "ppsspp-${DEVICE_ID}" > /tmp/pkg/meta/name
echo "${VERSION_CLEAN}" > /tmp/pkg/meta/version
echo "${DEVICE_ARCH}" > /tmp/pkg/meta/arch
echo "PPSSPP PlayStation Portable Emulator (${DEVICE_ID} build)" > /tmp/pkg/meta/description
echo "AstralEmu <noreply@astralemu.github.io>" > /tmp/pkg/meta/maintainer
echo "deb" > /tmp/pkg/meta/source_format
echo "noble" > /tmp/pkg/meta/source_distro
echo "games" > /tmp/pkg/meta/section
echo "optional" > /tmp/pkg/meta/priority
echo "ppsspp" > /tmp/pkg/meta/provides
echo "ppsspp" > /tmp/pkg/meta/conflicts
cat > /tmp/pkg/meta/depends << DEPS
libc6
libjemalloc2
libsdl2-2.0-0
libsdl2-ttf-2.0-0
libglew2.2
libsnappy1v5
libavcodec60
libavformat60
libswscale7
libzip4t64
libpng16-16t64
DEPS
tar cf /workspace/ppsspp-${DEVICE_ID}_${VERSION_CLEAN}_${DEVICE_ARCH}.pkg.tar -C /tmp/pkg meta root

ccache -s
echo "completed" > /workspace/build-status
