#!/bin/bash
set -e

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=5G
ccache -z

if [[ ! -d /workspace/src-esde ]]; then
  git clone https://gitlab.com/es-de/emulationstation-de.git /workspace/src-esde
fi

cd /workspace/src-esde
git fetch origin --tags
git checkout "$VERSION"
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
    -DCMAKE_SHARED_LINKER_FLAGS="-ljemalloc"
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
echo "emulationstation-de-${DEVICE_ID}" > /tmp/pkg/meta/name
echo "${VERSION_CLEAN}" > /tmp/pkg/meta/version
echo "${DEVICE_ARCH}" > /tmp/pkg/meta/arch
echo "EmulationStation Desktop Edition (${DEVICE_ID} build)" > /tmp/pkg/meta/description
echo "AstralEmu <noreply@astralemu.github.io>" > /tmp/pkg/meta/maintainer
echo "deb" > /tmp/pkg/meta/source_format
echo "noble" > /tmp/pkg/meta/source_distro
echo "games" > /tmp/pkg/meta/section
echo "optional" > /tmp/pkg/meta/priority
echo "emulationstation" > /tmp/pkg/meta/provides
echo "emulationstation" > /tmp/pkg/meta/conflicts
cat > /tmp/pkg/meta/depends << DEPS
libc6
libsdl2-2.0-0
libavcodec60
libavformat60
libswscale7
libfreeimage3
libfreetype6
libcurl4t64
libpugixml1v5
libvlc5
libpoppler-cpp0t64
DEPS
tar cf /workspace/emulationstation-de-${DEVICE_ID}_${VERSION_CLEAN}_${DEVICE_ARCH}.pkg.tar -C /tmp/pkg meta root

ccache -s
echo "completed" > /workspace/build-status
