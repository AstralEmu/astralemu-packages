#!/bin/bash
set -e
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=5G
ccache -z

export CFLAGS="$DEVICE_CFLAGS -flto=auto"
export CXXFLAGS="$DEVICE_CXXFLAGS -flto=auto"
export LDFLAGS="-flto=auto -shared -ljemalloc"

CORES_DIR=/workspace/libretro-cores
PKG_DIR=/workspace/cores-heavy-3
mkdir -p "$CORES_DIR" "$PKG_DIR"
cd "$CORES_DIR"

build_core() {
  local repo=$1
  local name=$2
  local subdir=${3:-}
  local make_args=${4:-}
  local pre_make=${5:-}
  local post_clean=${6:-}

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
  [[ -n "$pre_make" ]] && eval "$pre_make"
  [[ -n "$subdir" ]] && cd "$subdir"
  make clean 2>/dev/null || true
  [[ -n "$post_clean" ]] && eval "$post_clean"
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

# Batch 3: N64, PSX and Saturn cores
# mupen64plus-next on x86: pre-generate nasm headers that the parallel build races on.
# Make's dependency chain doesn't reliably order asm_defines generation before nasm.
# Fix: compile asm_defines.o via Make (needs project CFLAGS), then run AWK manually.
build_core mupen64plus-libretro-nx mupen64plus-next "" "" "" \
  'if [[ "$DEVICE_ARCH" == "amd64" ]]; then
    D=./mupen64plus-core/src/asm_defines
    make -j1 platform=unix CC="ccache gcc" CXX="ccache g++" SKIPDEPEND=1 WERROR=0 "$D/asm_defines.o" 2>&1 || true
    if [[ -f "$D/asm_defines.o" ]]; then
      strings "$D/asm_defines.o" | tr -d "\r" | awk -v dest_dir="$D" -f ./mupen64plus-core/tools/gen_asm_defines.awk
      echo "Pre-generated: $(ls "$D"/asm_defines_*.h 2>/dev/null)"
    fi
  fi'
build_core beetle-psx-libretro beetle-psx
build_core yabause yabause "yabause/src/libretro" "HAVE_SSE=0"

ccache -s
echo "completed" > /workspace/build-status-heavy-3
