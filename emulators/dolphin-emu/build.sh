#!/bin/bash
set -e

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=5G
ccache -z

if [[ ! -d /workspace/src-dolphin ]]; then
  git clone https://github.com/dolphin-emu/dolphin.git /workspace/src-dolphin
fi

cd /workspace/src-dolphin
git fetch origin
git checkout "$COMMIT"
git submodule update --init --recursive
mkdir -p build && cd build

if [[ ! -f build.ninja ]]; then
  cmake .. -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_C_FLAGS="$TARGET_CFLAGS -flto" \
    -DCMAKE_CXX_FLAGS="$TARGET_CXXFLAGS -flto" \
    -DCMAKE_EXE_LINKER_FLAGS="-ljemalloc" \
    -DCMAKE_SHARED_LINKER_FLAGS="-ljemalloc" \
    -DENABLE_VULKAN=ON \
    -DENABLE_X11=ON \
    -DENABLE_WAYLAND=ON \
    -DENABLE_TESTS=OFF \
    -DENABLE_ANALYTICS=OFF
fi

ninja -j$(nproc)
ccache -s

DESTDIR=/tmp/pkg/root ninja install
PKG_VERSION="0.0.0+git.${SHORT}"
mkdir -p /tmp/pkg/meta
echo "dolphin-emu-${TARGET_ID}" > /tmp/pkg/meta/name
bash /workspace/scripts/emit-aliases.sh dolphin-emu /tmp/pkg/meta
echo "${PKG_VERSION}" > /tmp/pkg/meta/version
echo "${TARGET_ARCH}" > /tmp/pkg/meta/arch
echo "Dolphin GameCube/Wii Emulator (${TARGET_ID} build)" > /tmp/pkg/meta/description
echo "games" > /tmp/pkg/meta/section
echo "optional" > /tmp/pkg/meta/priority
cat > /tmp/pkg/meta/depends << DEPS
libc6
libjemalloc2
libqt6widgets6
libqt6gui6
libqt6core6
libavcodec60
libavformat60
libswscale7
libevdev2
libminiupnpc17
libmbedtls14t64
libcurl4t64
libhidapi-hidraw0
libsystemd0
libbluetooth3
libasound2t64
libpulse0
libpugixml1v5
libbz2-1.0
libzstd1
liblzo2-2
libpng16-16t64
libusb-1.0-0
libfmt9
libsfml-system2.6
libsfml-network2.6
libxxhash0
libspng0
DEPS
bash /workspace/scripts/finalize-meta.sh /tmp/pkg/meta /workspace/src-dolphin
tar cf /workspace/dolphin-emu-${TARGET_ID}_${PKG_VERSION}_${TARGET_ARCH}.pkg.tar -C /tmp/pkg meta root

ccache -s
echo "completed" > /workspace/build-status
