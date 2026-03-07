#!/bin/bash
set -e

if [[ ! -d /workspace/src-zstd ]]; then
  git clone https://github.com/facebook/zstd.git /workspace/src-zstd
fi

cd /workspace/src-zstd
git fetch --tags
LATEST=$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -1)
echo "Using zstd: $LATEST"
git checkout "$LATEST"

cd build/cmake
mkdir -p builddir && cd builddir
cmake .. -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_C_FLAGS="$DEVICE_CFLAGS -flto=thin" \
  -DCMAKE_CXX_FLAGS="$DEVICE_CXXFLAGS -flto=thin" \
  -DZSTD_BUILD_PROGRAMS=OFF \
  -DZSTD_BUILD_TESTS=OFF \
  -DZSTD_BUILD_STATIC=OFF

ninja -j"$NPROC"
DESTDIR="$PREFIX" ninja install
ninja install
