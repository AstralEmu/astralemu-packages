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

# Mesa 26+ requires meson >= 1.4.0 (Ubuntu 24.04 ships 1.3.2)
pip3 install --break-system-packages meson mako --upgrade

# Mesa 26+ requires Rust >= 1.82, bindgen >= 0.71.1, and libclc
if ! rustc --version 2>/dev/null | grep -qE '1\.(8[2-9]|9[0-9]|[0-9]{3})'; then
  apt-get update && apt-get install -y --no-install-recommends libclc-18
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  source "$HOME/.cargo/env"
  cargo install bindgen-cli
fi

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

meson setup build --prefix=/usr --buildtype=release \
  -Db_lto=true -Db_lto_mode=thin \
  -Dc_args="$DEVICE_CFLAGS" \
  -Dcpp_args="$DEVICE_CXXFLAGS" \
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
