#!/bin/bash
set -e

if [[ ! -d /workspace/src-ffmpeg ]]; then
  git clone https://github.com/FFmpeg/FFmpeg.git /workspace/src-ffmpeg
fi

cd /workspace/src-ffmpeg
git fetch --tags
LATEST=$(git tag -l 'n[0-9]*.[0-9]*' | grep -v dev | sort -V | tail -1)
echo "Using FFmpeg: $LATEST"
git checkout "$LATEST"

./configure \
  --prefix=/usr \
  --enable-shared \
  --disable-static \
  --enable-gpl \
  --enable-version3 \
  --enable-vaapi \
  --enable-vdpau \
  --enable-vulkan \
  --enable-libdrm \
  --disable-doc \
  --disable-debug \
  --enable-lto=thin \
  --extra-cflags="$DEVICE_CFLAGS" \
  --extra-cxxflags="$DEVICE_CXXFLAGS" \
  --cc="ccache gcc" \
  --cxx="ccache g++"

make -j"$NPROC"
make DESTDIR="$PREFIX" install
make install
