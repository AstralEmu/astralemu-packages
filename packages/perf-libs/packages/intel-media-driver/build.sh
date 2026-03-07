#!/bin/bash
set -e

# gmmlib (required by intel-media-driver)
if [[ ! -d /workspace/src-gmmlib ]]; then
  git clone https://github.com/intel/gmmlib.git /workspace/src-gmmlib
fi

cd /workspace/src-gmmlib
git fetch --tags
LATEST=$(git tag -l 'intel-gmmlib-[0-9]*' | sort -V | tail -1)
echo "Using gmmlib: $LATEST"
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
  -DCMAKE_SHARED_LINKER_FLAGS="$DEVICE_LDFLAGS"

ninja -j"$NPROC"
DESTDIR="$PREFIX" ninja install
ninja install

# intel-media-driver
if [[ ! -d /workspace/src-intel-media ]]; then
  git clone https://github.com/intel/media-driver.git /workspace/src-intel-media
fi

cd /workspace/src-intel-media
git fetch --tags
LATEST=$(git tag -l 'intel-media-[0-9]*' | sort -V | tail -1)
echo "Using intel-media-driver: $LATEST"
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
  -DMEDIA_BUILD_FATAL_WARNINGS=OFF

ninja -j"$NPROC"
DESTDIR="$PREFIX" ninja install
ninja install
