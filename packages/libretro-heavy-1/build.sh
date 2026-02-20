#!/bin/bash
set -e
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=5G
ccache -z

export CFLAGS="$DEVICE_CFLAGS -flto=auto"
export CXXFLAGS="$DEVICE_CXXFLAGS -flto=auto"
export LDFLAGS="-flto=auto -shared -ljemalloc"

CORES_DIR=/workspace/libretro-cores
PKG_DIR=/workspace/cores-heavy-1
mkdir -p "$CORES_DIR" "$PKG_DIR"
cd "$CORES_DIR"

build_core() {
  local repo=$1
  local name=$2
  local subdir=${3:-}
  local make_args=${4:-}

  echo "=== Building $name ==="
  if [[ -d "$name" ]] && [[ -f "$name/.gitmodules" ]] && [[ -z "$(ls -A "$name/libretro-common" 2>/dev/null)" ]]; then
    rm -rf "$name"
  fi
  if [[ ! -d "$name" ]]; then
    if ! git clone --depth 1 --recursive "https://github.com/libretro/$repo.git" "$name"; then
      echo "ERROR: Failed to clone $repo, skipping $name..."
      return 1
    fi
  fi
  cd "$name"
  [[ -n "$subdir" ]] && cd "$subdir"
  make clean 2>/dev/null || true
  timeout ${BUILD_TIMEOUT}s make -j$(nproc) platform=unix $make_args \
    CC="ccache gcc" CXX="ccache g++" \
    LDFLAGS="$LDFLAGS" SKIPDEPEND=1 WERROR=0 || {
    EXIT_CODE=$?
    [[ $EXIT_CODE -eq 124 ]] && echo "TIMEOUT on $name" && exit 124
    exit $EXIT_CODE
  }
  find . -name "*.so" -exec cp {} "$PKG_DIR/" \;
  cd "$CORES_DIR"
}

# Batch 1: MAME, VICE, DOSBox, Saturn
build_core mame2003-plus-libretro mame2003-plus
build_core vice-libretro vice "" "EMUTYPE=x64"
build_core dosbox-pure dosbox-pure
build_core beetle-saturn-libretro beetle-saturn

ccache -s
echo "completed" > /workspace/build-status-heavy-1
