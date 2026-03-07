#!/bin/bash
set -e

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=5G
ccache -z

if [[ ! -d /workspace/src-xemu ]]; then
  git clone https://github.com/xemu-project/xemu.git /workspace/src-xemu
fi

cd /workspace/src-xemu
git fetch origin --tags
git checkout "$VERSION"
git submodule update --init --recursive

export CFLAGS="$DEVICE_CFLAGS -flto"
export CXXFLAGS="$DEVICE_CXXFLAGS -flto"
export LDFLAGS="-ljemalloc"

# Build with X11 (XWayland)
timeout ${BUILD_TIMEOUT}s ./build.sh --enable-sdl --disable-werror || {
  EXIT_CODE=$?
  ccache -s
  if [[ $EXIT_CODE -eq 124 ]]; then
    echo "timeout" > /workspace/build-status
    exit 0
  fi
  exit $EXIT_CODE
}

mkdir -p /tmp/pkg/root/usr/bin /tmp/pkg/root/usr/share/applications
cp dist/xemu /tmp/pkg/root/usr/bin/

cat > /tmp/pkg/root/usr/share/applications/xemu.desktop << DESK
[Desktop Entry]
Name=xemu
Comment=Original Xbox Emulator
Exec=xemu
Icon=xemu
Terminal=false
Type=Application
Categories=Game;Emulator;
DESK

VERSION_CLEAN=$(echo "$VERSION" | sed "s/^v//")
mkdir -p /tmp/pkg/meta
echo "xemu-${DEVICE_ID}" > /tmp/pkg/meta/name
echo "${VERSION_CLEAN}" > /tmp/pkg/meta/version
echo "${DEVICE_ARCH}" > /tmp/pkg/meta/arch
echo "xemu Original Xbox Emulator (${DEVICE_ID} build)" > /tmp/pkg/meta/description
echo "AstralEmu <noreply@astralemu.github.io>" > /tmp/pkg/meta/maintainer
echo "deb" > /tmp/pkg/meta/source_format
echo "noble" > /tmp/pkg/meta/source_distro
echo "games" > /tmp/pkg/meta/section
echo "optional" > /tmp/pkg/meta/priority
cat > /tmp/pkg/meta/depends << DEPS
libc6
libjemalloc2
libsdl2-2.0-0
libepoxy0
libpixman-1-0
libgtk-3-0t64
libssl3t64
libsamplerate0
libpcap0.8t64
libslirp0
DEPS
tar cf /workspace/xemu-${DEVICE_ID}_${VERSION_CLEAN}_${DEVICE_ARCH}.pkg.tar -C /tmp/pkg meta root

ccache -s
echo "completed" > /workspace/build-status
