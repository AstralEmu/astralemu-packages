#!/bin/bash
set -e

if [[ ! -d /workspace/src-libdrm ]]; then
  git clone https://gitlab.freedesktop.org/mesa/drm.git /workspace/src-libdrm
fi

cd /workspace/src-libdrm
git fetch --tags
LATEST=$(git tag -l 'libdrm-[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -1)
echo "Using libdrm: $LATEST"
git checkout "$LATEST"

EXTRA_OPTS=""
if $IS_ARM; then
  EXTRA_OPTS="-Dfreedreno=enabled -Dtegra=enabled -Detnaviv=enabled"
fi

meson setup build --prefix=/usr --buildtype=release \
  -Db_lto=true -Db_lto_mode=thin \
  -Dc_args="$TARGET_CFLAGS" \
  -Dcpp_args="$TARGET_CXXFLAGS" \
  -Dintel=enabled \
  -Damdgpu=enabled \
  -Dnouveau=enabled \
  -Dradeon=enabled \
  $EXTRA_OPTS

ninja -C build -j"$NPROC"
DESTDIR="$PREFIX" ninja -C build install
ninja -C build install
