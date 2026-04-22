#!/bin/bash
set -e

if [[ ! -d /workspace/src-mesa ]]; then
  git clone https://gitlab.freedesktop.org/mesa/mesa.git /workspace/src-mesa
fi

cd /workspace/src-mesa
git fetch --tags
LATEST=$(git tag -l 'mesa-[0-9]*' | sort -V | tail -1)
echo "Using Mesa: $LATEST"
git checkout "$LATEST"
# Reset any previously applied patches from a prior run in the same workspace
git reset --hard "$LATEST" >/dev/null
git clean -fd >/dev/null

# Apply Turnip tweaks on Snapdragon-capable targets only. These modify
# src/freedreno/ which is only loaded at runtime on Adreno GPUs, so the
# same binary stays inert on RPi5 (v3d) and RK3588 (panfrost).
PATCH_DIR="$(dirname "${BASH_SOURCE[0]}")/patches"
if [[ "${TARGET_ID:-}" == "arm64-modern" && -d "$PATCH_DIR" ]]; then
  echo "Applying Turnip patches for $TARGET_ID:"
  for p in "$PATCH_DIR"/*.patch; do
    [[ -f "$p" ]] || continue
    echo "  -> $(basename "$p")"
    git apply --check "$p" || { echo "ERROR: patch $(basename "$p") does not apply to Mesa $LATEST" >&2; exit 1; }
    git apply "$p"
  done
fi

# =============================================================================
# Dependencies
# =============================================================================
# Strategy: let Debian do the work for us. "apt-get build-dep mesa" installs
# the full dependency set that the Debian/Ubuntu Mesa maintainers curate
# (libdrm-dev, libexpat1-dev, x11/xcb/xkb/wayland protocols, llvm-dev, valgrind,
# python3-mako, etc.). Upstream Mesa recommends this approach in docs/install.rst.
#
# Then we add the deltas Mesa 26+ needs that are newer than the version shipped
# by the base (24.04 ships Mesa 24.0.x):
#   - Newer LLVM/Clang headers + libs for CLC/OpenCL/NVK paths
#   - libxshmfence-dev, libwayland-egl-backend-dev (sometimes split out)
#
# Python and Rust toolchain extras go via pip/cargo since Ubuntu 24.04 ships
# older versions than Mesa 26 requires.

# Enable deb-src on Ubuntu 24.04's deb822-format sources so build-dep works
if ! grep -q '^Types: deb deb-src' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null; then
  sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
fi
apt-get update

# Full Debian build-deps for Mesa (self-healing: follows upstream Debian recipe)
apt-get build-dep -y --no-install-recommends mesa || \
  echo "WARN: apt build-dep mesa failed, falling back to explicit packages"

# Mesa 26+ deltas not yet in Ubuntu 24.04's Mesa build-deps
apt-get install -y --no-install-recommends \
  libclc-18 \
  libllvmspirvlib-18-dev \
  libclang-cpp18-dev \
  libclang-18-dev \
  libwayland-egl-backend-dev \
  libxshmfence-dev

# Python deps: Mesa 26+ needs meson >= 1.4.0 (noble ships 1.3.2), pycparser
# >= 2.20 for etnaviv hwdb, and packaging module on Python 3.12+
pip3 install --break-system-packages --upgrade \
  meson mako pycparser packaging pyyaml

# Rust + bindgen + cbindgen — Mesa 26+ requires Rust >= 1.82 (noble ships 1.75)
# for rusticl, NAK (NVK compiler), and nouveau NIL
if ! rustc --version 2>/dev/null | grep -qE '1\.(8[2-9]|9[0-9]|[0-9]{3})'; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  source "$HOME/.cargo/env"
fi
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"
command -v bindgen  >/dev/null || cargo install bindgen-cli
command -v cbindgen >/dev/null || cargo install cbindgen

GALLIUM="llvmpipe,softpipe,virgl"
VULKAN=""

if $IS_X86; then
  GALLIUM="$GALLIUM,radeonsi,iris,crocus,nouveau,zink"
  VULKAN="amd,intel,intel_hasvk,swrast,nouveau"
fi

if $IS_ARM; then
  GALLIUM="$GALLIUM,panfrost,lima,v3d,vc4,freedreno,etnaviv,tegra,nouveau,zink"
  VULKAN="broadcom,freedreno,panfrost,swrast,nouveau"
fi

meson setup build --prefix=/usr --buildtype=release --reconfigure \
  -Db_lto=false \
  -Dc_args="$TARGET_CFLAGS" \
  -Dcpp_args="$TARGET_CXXFLAGS" \
  -Dgallium-drivers="$GALLIUM" \
  -Dvulkan-drivers="$VULKAN" \
  -Dplatforms=x11,wayland \
  -Degl=enabled \
  -Dgbm=enabled \
  -Dgles1=enabled \
  -Dgles2=enabled \
  -Dglx=dri \
  -Dllvm=enabled \
  -Dshared-llvm=enabled \
  -Dgallium-va=enabled \
  -Dvideo-codecs=all

ninja -C build -j"$NPROC"
DESTDIR="$PREFIX" ninja -C build install
ninja -C build install
