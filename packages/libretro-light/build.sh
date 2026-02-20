#!/bin/bash
set -e

export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=5G
ccache -z

# -Wno-error prevents warnings from failing the build
export CFLAGS="$DEVICE_CFLAGS -flto -Wno-error"
export CXXFLAGS="$DEVICE_CXXFLAGS -flto -Wno-error"
export LDFLAGS="-flto -ljemalloc"

CORES_DIR=/workspace/libretro-cores
PKG_DIR=/workspace/cores-light
mkdir -p "$CORES_DIR" "$PKG_DIR"

cd "$CORES_DIR"

build_core() {
  local repo=$1
  local name=$2
  local subdir=${3:-}
  local make_args=${4:-}

  echo "=== Building $name ==="
  if [[ -d "$name" ]] && [[ -f "$name/.gitmodules" ]] && [[ -z "$(ls -A "$name/libretro-common" 2>/dev/null)" ]]; then
    echo "Submodules missing in cached $name, re-cloning..."
    rm -rf "$name"
  fi
  if [[ ! -d "$name" ]]; then
    if ! git clone --depth 1 --recursive "https://github.com/libretro/$repo.git" "$name"; then
      echo "WARNING: Failed to clone $repo, skipping $name..."
      return 0
    fi
  fi
  cd "$name"
  if [[ -n "$subdir" ]]; then
    cd "$subdir"
  fi
  make clean 2>/dev/null || true
  if make -j$(nproc) platform=unix $make_args \
    CC="ccache gcc" CXX="ccache g++" \
    CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS"; then
    find . -name "*.so" -exec cp {} "$PKG_DIR/" \;
  else
    echo "WARNING: Failed to build $name, skipping..."
  fi
  cd "$CORES_DIR"
}

# Computers (fmsx has broken source code, use bluemsx instead)
# build_core fmsx-libretro fmsx
build_core blueMSX-libretro bluemsx
build_core PUAE puae
build_core fuse-libretro fuse
build_core libretro-cap32 cap32
build_core libretro-atari800 atari800
build_core px68k-libretro px68k
build_core quasi88-libretro quasi88

# Consoles
build_core opera-libretro opera
build_core neocd_libretro neocd
build_core virtualjaguar-libretro virtualjaguar
build_core libretro-o2em o2em
build_core libretro-vecx vecx
build_core FreeChaF freechaf
build_core FreeIntv freeintv
build_core geolith-libretro geolith

# Standard consoles
build_core beetle-pce-fast-libretro beetle-pce-fast
build_core beetle-supergrafx-libretro beetle-supergrafx
build_core beetle-vb-libretro beetle-vb
build_core beetle-wswan-libretro beetle-wswan
build_core libretro-fceumm fceumm
build_core gambatte-libretro gambatte
build_core Genesis-Plus-GX genesis-plus-gx
build_core gpsp gpsp
build_core libretro-handy handy
build_core beetle-gba-libretro mednafen-gba
build_core beetle-ngp-libretro mednafen-ngp
build_core beetle-pce-libretro mednafen-pce
build_core mgba mgba
build_core nestopia nestopia "libretro"
build_core pcsx_rearmed pcsx-rearmed
build_core picodrive picodrive
build_core prosystem-libretro prosystem
build_core QuickNES_Core quicknes
build_core SameBoy sameboy "libretro"
build_core snes9x snes9x "libretro"
build_core stella2014-libretro stella
build_core tgbdual-libretro tgbdual
build_core vba-next vba-next

# Games
build_core libretro-prboom prboom
build_core nxengine-libretro nxengine

ccache -s
echo "completed" > /workspace/build-status-light
