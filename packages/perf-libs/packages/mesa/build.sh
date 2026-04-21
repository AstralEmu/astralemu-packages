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

# Mesa 26+ requires meson >= 1.4.0 (Ubuntu 24.04 ships 1.3.2)
pip3 install --break-system-packages meson mako --upgrade

# Mesa 26+ extra system deps not in the base image:
#   libclc-18                — OpenCL C headers for compute shaders
#   libllvmspirvlib-18-dev   — SPIR-V <-> LLVM translator
#   libclang-cpp18-dev       — gates the CLC path pulled in by llvmspirvlib;
#                              Mesa tries clang-cpp first, then falls back to
#                              per-module clangBasic/clangAST/etc.
#   bison flex               — required whenever gallium/GL/vulkan is enabled
#                              (needs_flex_bison = with_any_opengl or ...)
#   libelf-dev               — used by freedreno ir3 dbg and some gallium bits
apt-get update && apt-get install -y --no-install-recommends \
  libclc-18 libllvmspirvlib-18-dev libclang-cpp18-dev \
  bison flex libelf-dev

# Mesa 26+ also requires Rust >= 1.82 and bindgen >= 0.71.1 for rusticl/NAK.
if ! rustc --version 2>/dev/null | grep -qE '1\.(8[2-9]|9[0-9]|[0-9]{3})'; then
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
