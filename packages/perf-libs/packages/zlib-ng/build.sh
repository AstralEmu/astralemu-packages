#!/bin/bash
set -e

if [[ ! -d /workspace/src-zlib-ng ]]; then
  git clone https://github.com/zlib-ng/zlib-ng.git /workspace/src-zlib-ng
fi

cd /workspace/src-zlib-ng
git fetch --tags
LATEST=$(git tag -l '[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -1)
echo "Using zlib-ng: $LATEST"
git checkout "$LATEST"

mkdir -p build && cd build
cmake .. -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_C_FLAGS="$DEVICE_CFLAGS -flto=thin" \
  -DCMAKE_CXX_FLAGS="$DEVICE_CXXFLAGS -flto=thin" \
  -DZLIB_COMPAT=ON \
  -DWITH_GTEST=OFF

ninja -j"$NPROC"
DESTDIR="$PREFIX" ninja install
ninja install
