#!/bin/bash
set -e

if [[ ! -d /workspace/src-llvm ]]; then
  git clone https://github.com/llvm/llvm-project.git /workspace/src-llvm
fi

cd /workspace/src-llvm
git fetch --tags
LATEST=$(git tag -l 'llvmorg-[0-9]*.[0-9]*.[0-9]' | sort -V | tail -1)
echo "Using LLVM: $LATEST"
git checkout "$LATEST"

LLVM_TARGETS="X86;AMDGPU"
if $IS_ARM; then
  LLVM_TARGETS="AArch64;AMDGPU"
fi

cd llvm
mkdir -p build && cd build
cmake .. -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_C_FLAGS="$DEVICE_CFLAGS -flto=thin" \
  -DCMAKE_CXX_FLAGS="$DEVICE_CXXFLAGS -flto=thin" \
  -DLLVM_ENABLE_PROJECTS="clang" \
  -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGETS" \
  -DLLVM_BUILD_LLVM_DYLIB=ON \
  -DLLVM_LINK_LLVM_DYLIB=ON \
  -DLLVM_ENABLE_RTTI=ON \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_DOCS=OFF

ninja -j"$NPROC"
DESTDIR="$PREFIX" ninja install
ninja install
