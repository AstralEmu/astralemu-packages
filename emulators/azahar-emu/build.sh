#!/bin/bash
set -e

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=5G
ccache -z

if [[ ! -d /workspace/src-azahar ]]; then
  git clone https://github.com/azahar-emu/azahar.git /workspace/src-azahar
fi

cd /workspace/src-azahar
git fetch origin --tags
git checkout "$VERSION"
git submodule update --init --recursive

# Fix X11 None macro conflict
{ echo "#ifdef None"; echo "#undef None"; echo "#endif"; cat src/common/settings.h; } > src/common/settings.h.tmp
mv src/common/settings.h.tmp src/common/settings.h

mkdir -p build && cd build

if [[ ! -f build.ninja ]]; then
  cmake .. -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_C_FLAGS="$DEVICE_CFLAGS -flto=thin" \
    -DCMAKE_CXX_FLAGS="$DEVICE_CXXFLAGS -flto=thin" \
    -DCMAKE_EXE_LINKER_FLAGS="-ljemalloc" \
    -DCMAKE_SHARED_LINKER_FLAGS="-ljemalloc" \
    -DENABLE_VULKAN=ON \
    -DENABLE_OPENGL=ON \
    -DENABLE_QT_GUI=ON \
    -DENABLE_SDL2_FRONTEND=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_WEB_SERVICE=OFF \
    -DENABLE_X11=ON
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

DESTDIR=/tmp/pkg/root ninja install
VERSION_CLEAN=$(echo "$VERSION" | sed "s/^v//")
mkdir -p /tmp/pkg/meta
echo "azahar-emu-${DEVICE_ID}" > /tmp/pkg/meta/name
echo "${VERSION_CLEAN}" > /tmp/pkg/meta/version
echo "${DEVICE_ARCH}" > /tmp/pkg/meta/arch
echo "Azahar 3DS Emulator (${DEVICE_ID} build)" > /tmp/pkg/meta/description
echo "AstralEmu <noreply@astralemu.github.io>" > /tmp/pkg/meta/maintainer
echo "deb" > /tmp/pkg/meta/source_format
echo "noble" > /tmp/pkg/meta/source_distro
echo "games" > /tmp/pkg/meta/section
echo "optional" > /tmp/pkg/meta/priority
echo "citra" > /tmp/pkg/meta/provides
echo "citra" > /tmp/pkg/meta/replaces
cat > /tmp/pkg/meta/depends << DEPS
libc6
libjemalloc2
libqt6widgets6
libqt6gui6
libqt6core6
libqt6multimedia6
libqt6opengl6
libsdl2-2.0-0
libssl3t64
libavcodec60
libavformat60
libswscale7
libspeexdsp1
libfmt9
libzstd1
libusb-1.0-0
libhidapi-hidraw0
libboost-serialization1.83.0
libenet7
liblz4-1
DEPS
tar cf /workspace/azahar-emu-${DEVICE_ID}_${VERSION_CLEAN}_${DEVICE_ARCH}.pkg.tar -C /tmp/pkg meta root

ccache -s
echo "completed" > /workspace/build-status
