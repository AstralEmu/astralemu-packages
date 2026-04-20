#!/bin/bash
set -e

if [[ ! -d /workspace/src-libva ]]; then
  git clone https://github.com/intel/libva.git /workspace/src-libva
fi

cd /workspace/src-libva
git fetch --tags
LATEST=$(git tag -l '[0-9]*.[0-9]*.[0-9]*' | grep -v '_' | sort -V | tail -1)
echo "Using libva: $LATEST"
git checkout "$LATEST"

meson setup build --prefix=/usr --buildtype=release \
  -Db_lto=true -Db_lto_mode=thin \
  -Dc_args="$TARGET_CFLAGS" \
  -Dcpp_args="$TARGET_CXXFLAGS"

ninja -C build -j"$NPROC"
DESTDIR="$PREFIX" ninja -C build install
ninja -C build install
