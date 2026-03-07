#!/bin/bash
set -e

# Fetch latest Vulkan release version
if [[ ! -d /workspace/src-vulkan-headers ]]; then
  git clone https://github.com/KhronosGroup/Vulkan-Headers.git /workspace/src-vulkan-headers
fi

cd /workspace/src-vulkan-headers
git fetch --tags
LATEST=$(git tag -l 'v[0-9]*' | sort -V | tail -1)
echo "Using Vulkan: $LATEST"
git checkout "$LATEST"

mkdir -p build && cd build
cmake .. -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr
ninja -j"$NPROC"
DESTDIR="$PREFIX" ninja install
ninja install

# Vulkan-Loader with same version
if [[ ! -d /workspace/src-vulkan-loader ]]; then
  git clone https://github.com/KhronosGroup/Vulkan-Loader.git /workspace/src-vulkan-loader
fi

cd /workspace/src-vulkan-loader
git fetch --tags
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
  -DVULKAN_HEADERS_INSTALL_DIR=/usr \
  -DBUILD_TESTS=OFF

ninja -j"$NPROC"
DESTDIR="$PREFIX" ninja install
ninja install
