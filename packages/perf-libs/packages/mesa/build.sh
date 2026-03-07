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

GALLIUM="swrast,virgl"
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
  -Dgallium-vdpau=enabled \
  -Dgallium-xa=disabled \
  -Dvideo-codecs=all \
  -Dgallium-nine=true

ninja -C build -j"$NPROC"
DESTDIR="$PREFIX" ninja -C build install
ninja -C build install
