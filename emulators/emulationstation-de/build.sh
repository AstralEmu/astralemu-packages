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
    -DCMAKE_C_FLAGS="$TARGET_CFLAGS -flto" \
    -DCMAKE_CXX_FLAGS="$TARGET_CXXFLAGS -flto" \
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
echo "emulationstation-de-${TARGET_ID}" > /tmp/pkg/meta/name
echo "${VERSION_CLEAN}" > /tmp/pkg/meta/version
echo "${TARGET_ARCH}" > /tmp/pkg/meta/arch
echo "EmulationStation Desktop Edition (${TARGET_ID} build)" > /tmp/pkg/meta/description
echo "AstralEmu <noreply@astralemu.github.io>" > /tmp/pkg/meta/maintainer
echo "deb" > /tmp/pkg/meta/source_format
echo "noble" > /tmp/pkg/meta/source_distro
echo "games" > /tmp/pkg/meta/section
echo "optional" > /tmp/pkg/meta/priority
echo "emulationstation" > /tmp/pkg/meta/provides
echo "emulationstation" > /tmp/pkg/meta/conflicts
# Append device-name aliases AFTER the hardcoded provides so they coexist
# with the upstream virtual name ("emulationstation"). emit-aliases.sh uses
# >> so existing entries are preserved.
bash /workspace/scripts/emit-aliases.sh emulationstation-de /tmp/pkg/meta
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
tar cf /workspace/emulationstation-de-${TARGET_ID}_${VERSION_CLEAN}_${TARGET_ARCH}.pkg.tar -C /tmp/pkg meta root

ccache -s
echo "completed" > /workspace/build-status
