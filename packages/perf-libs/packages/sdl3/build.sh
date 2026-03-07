#!/bin/bash
set -e

if [[ ! -d /workspace/src-sdl3 ]]; then
  git clone https://github.com/libsdl-org/SDL.git /workspace/src-sdl3
fi

cd /workspace/src-sdl3
git fetch --tags
LATEST=$(git tag -l 'release-[0-9]*' | sort -V | tail -1)
echo "Using SDL3: $LATEST"
git checkout "$LATEST"

mkdir -p build && cd build
cmake .. -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_C_FLAGS="$DEVICE_CFLAGS -flto=thin" \
  -DCMAKE_CXX_FLAGS="$DEVICE_CXXFLAGS -flto=thin" \
  -DCMAKE_EXE_LINKER_FLAGS="$DEVICE_LDFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$DEVICE_LDFLAGS" \
  -DSDL_SHARED=ON \
  -DSDL_STATIC=OFF \
  -DSDL_TESTS=OFF

ninja -j"$NPROC"
DESTDIR="$PREFIX" ninja install
ninja install
