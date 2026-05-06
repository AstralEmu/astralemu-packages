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
  -DCMAKE_C_FLAGS="$TARGET_CFLAGS -flto=thin" \
  -DCMAKE_CXX_FLAGS="$TARGET_CXXFLAGS -flto=thin" \
  -DCMAKE_EXE_LINKER_FLAGS="$TARGET_LDFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$TARGET_LDFLAGS"

ninja -j"$NPROC"
DESTDIR="$PREFIX" ninja install
ninja install

# intel-media-driver
if [[ ! -d /workspace/src-intel-media ]]; then
  git clone https://github.com/intel/media-driver.git /workspace/src-intel-media
fi

cd /workspace/src-intel-media
git fetch --tags
LATEST=$(git tag -l 'intel-media-[0-9]*' | grep -v '^intel-media-600\.' | sort -V | tail -1)
echo "Using intel-media-driver: $LATEST"
git checkout "$LATEST"

# Build from root (the repo switched to a flat layout).
# -DMEDIA_RUN_TEST_SUITE=OFF skips the ULT subdirectory whose CMakeLists
# has a broken `if()` on undefined variables when not building in
# ReleaseInternal mode. -DMEDIA_BUILD_FATAL_WARNINGS=OFF ignores -Werror.
mkdir -p build && cd build
cmake .. -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_C_FLAGS="$TARGET_CFLAGS -flto=thin" \
  -DCMAKE_CXX_FLAGS="$TARGET_CXXFLAGS -flto=thin" \
  -DCMAKE_EXE_LINKER_FLAGS="$TARGET_LDFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$TARGET_LDFLAGS" \
  -DMEDIA_BUILD_FATAL_WARNINGS=OFF \
  -DMEDIA_RUN_TEST_SUITE=OFF \
  -DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu

ninja -j"$NPROC"
DESTDIR="$PREFIX" ninja install
ninja install
