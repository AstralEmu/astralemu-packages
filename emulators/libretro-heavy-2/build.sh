#!/bin/bash
set -e
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=5G
ccache -z

export CFLAGS="$TARGET_CFLAGS -flto=auto"
export CXXFLAGS="$TARGET_CXXFLAGS -flto=auto"
export LDFLAGS="-flto=auto -shared -ljemalloc"

CORES_DIR=/workspace/libretro-cores
PKG_DIR=/workspace/cores-heavy-2
mkdir -p "$CORES_DIR" "$PKG_DIR"
cd "$CORES_DIR"

build_core() {
  local repo=$1
  local name=$2
  local subdir=${3:-}
  local make_args=${4:-}
  local pre_make=${5:-}
  local post_clean=${6:-}

  # Default to the libretro org. A repo arg of "<org>/<name>" overrides the
  # org for cores where the canonical upstream lives outside libretro.
  local clone_url
  case "$repo" in
    */*) clone_url="https://github.com/${repo}.git" ;;
    *)   clone_url="https://github.com/libretro/${repo}.git" ;;
  esac

  echo "=== Building $name (from $clone_url) ==="
  # Force fresh clone if Makefile is missing (happens when cache is corrupted)
  if [[ ! -f "$name/Makefile" ]]; then
    rm -rf "$name"
  fi
  if [[ ! -d "$name" ]]; then
    if ! git clone --depth 1 "$clone_url" "$name"; then
      echo "ERROR: Failed to clone $repo, skipping $name..."
      return 1
    fi
    if [[ -f "$name/.gitmodules" ]]; then
      echo "  Initializing submodules for $name..."
      (cd "$name" && git submodule update --init --recursive --depth 1) || {
        echo "WARNING: Submodule init failed for $name, continuing anyway"
      }
    fi
  fi
  # Verify Makefile exists before proceeding
  if [[ ! -f "$name/Makefile" ]]; then
    echo "ERROR: No Makefile in $name after clone, skipping..."
    return 1
  fi
  cd "$name"
  [[ -n "$pre_make" ]] && eval "$pre_make"
  [[ -n "$subdir" ]] && cd "$subdir"
  make clean 2>/dev/null || true
  [[ -n "$post_clean" ]] && eval "$post_clean"
  make -j$(nproc) platform=unix $make_args \
    CC="ccache gcc" CXX="ccache g++" \
    LDFLAGS="$LDFLAGS" SKIPDEPEND=1 WERROR=0
  find . -name "*.so" -exec cp {} "$PKG_DIR/" \;
  cd "$CORES_DIR"
}

# --- Flycast (CMake-based, not Makefile) ---
# flyinghead/flycast uses CMake; the deprecated libretro/flycast had a Makefile.
# Clone with submodules (tinygettext, Vulkan-Headers, VulkanMemoryAllocator,
# xbyak, etc. are required for the CMake build).
echo "=== Building flycast (CMake) ==="
if [[ -d flycast ]]; then
  rm -rf flycast
fi
git clone --depth 1 https://github.com/flyinghead/flycast.git flycast
(cd flycast && git submodule update --init --recursive --depth 1)
cd flycast
mkdir -p build && cd build
cmake .. -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_C_FLAGS="$CFLAGS" \
  -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
  -DLIBRETRO=ON \
  -DHAVE_GENERIC_JIT=OFF
ninja -j"$(nproc)"
find . -name "flycast_libretro.so" -exec cp {} "$PKG_DIR/" \;
cd "$CORES_DIR"

# scummvm on x86: disable libco inline asm (LTO + RIP-relative TLS = wrong relocations)
# deps/libretro-common is managed by configure_submodules.sh (NOT a git submodule).
# The script runs during Makefile parsing via $(shell) and resets dirty repos with
# git reset --hard, undoing any direct sed patches. Wrap it to auto-patch libco/amd64.c
# after every fetch/reset cycle.
_SCUMMVM_WRAP='#!/bin/bash
DIR="$(dirname "$0")"
OUT=$("$DIR/configure_submodules.sh.orig" "$@")
P=$3/${5:-$(echo $1 | sed "s|.*/||")}
[ -f "$P/libco/amd64.c" ] && sed -i "/#define CO_USE_INLINE_ASM/d" "$P/libco/amd64.c"
echo "$OUT"'
build_core scummvm scummvm "backends/platform/libretro" "" \
  '[[ "$TARGET_ARCH" == "amd64" ]] && { S=backends/platform/libretro/scripts/configure_submodules.sh; [[ ! -f "${S}.orig" ]] && cp "$S" "${S}.orig"; echo "$_SCUMMVM_WRAP" > "$S"; chmod +x "$S"; } || true'

ccache -s
echo "completed" > /workspace/build-status-heavy-2
