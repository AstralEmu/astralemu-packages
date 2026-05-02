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
#
# Best-effort: Turnip patches come from a third-party upstream and bitrot
# as Mesa refactors. Individual patch failures are logged but don't abort
# the build — a missing tweak just means upstream Turnip is used for that
# device, not that the whole target is broken. Patches are applied via
# `git am --reject` so conflicting hunks become .rej files instead of
# leaving the tree dirty mid-apply.
PATCH_DIR="$(dirname "${BASH_SOURCE[0]}")/patches"
if [[ "${TARGET_ID:-}" == "arm64-modern" && -d "$PATCH_DIR" ]]; then
  echo "Applying Turnip patches for $TARGET_ID:"
  applied=0 skipped=0
  for p in "$PATCH_DIR"/*.patch; do
    [[ -f "$p" ]] || continue
    name=$(basename "$p")
    if git apply --check "$p" 2>/dev/null && git apply "$p" 2>/dev/null; then
      echo "  OK   $name"
      applied=$((applied+1))
    else
      echo "  SKIP $name (does not apply to $LATEST — bitrot, using upstream Turnip for affected GPUs)"
      skipped=$((skipped+1))
      # Reset any partial state before continuing
      git checkout -- . 2>/dev/null || true
    fi
  done
  echo "Turnip patches: $applied applied, $skipped skipped"
fi

# =============================================================================
# Dependencies
# =============================================================================
# Strategy: let Debian do the work for us. "apt-get build-dep mesa" installs
# the full dependency set that the Debian/Ubuntu Mesa maintainers curate
# (libdrm-dev, libexpat1-dev, x11/xcb/xkb/wayland protocols, llvm-dev, valgrind,
# python3-mako, etc.). Upstream Mesa recommends this approach in docs/install.rst.
#
# Then we add the deltas Mesa upstream may need that the base distro hasn't
# yet caught up on (varies by Ubuntu LTS — fewer deltas as base modernizes).
#
# Python and Rust extras go via pip/cargo when the distro version is below
# the minimum Mesa needs; ensure_min skips no-op when the system already
# has a recent enough copy (= cheap, idempotent).

# Enable deb-src on Ubuntu's deb822-format sources so build-dep works
if ! grep -q '^Types: deb deb-src' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null; then
  sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
fi
apt-get update

# Full Debian build-deps for Mesa (self-healing: follows upstream Debian recipe)
apt-get build-dep -y --no-install-recommends mesa || \
  echo "WARN: apt build-dep mesa failed, falling back to explicit packages"

# Pick the system LLVM version and install the matching headers/libs that
# Mesa needs but apt build-dep doesn't pull (CLC path, libclang-cpp, etc.).
# Probing the version makes this work across rolling Ubuntu LTS bumps
# without hardcoding -18 / -19 / -20 in every place.
LLVM_VER=$(apt-cache search '^libllvm[0-9]+$' 2>/dev/null \
  | awk -F'libllvm' '{print $2}' | awk '{print $1}' \
  | sort -V | tail -n1)
if [[ -n "$LLVM_VER" ]]; then
  echo "Detected system LLVM major version: $LLVM_VER"
  apt-get install -y --no-install-recommends \
    "libclc-${LLVM_VER}" \
    "libllvmspirvlib-${LLVM_VER}-dev" \
    "libclang-cpp${LLVM_VER}-dev" \
    "libclang-${LLVM_VER}-dev"
fi
apt-get install -y --no-install-recommends \
  libwayland-egl-backend-dev \
  libxshmfence-dev

# Python deps: Mesa needs meson >= 1.4.0, pycparser >= 2.20 for etnaviv
# hwdb, packaging on Python 3.12+. Some of these ship as distutils-installed
# on older Ubuntu (no RECORD file); ensure_min upgrades only when needed.
pip3 install --break-system-packages --upgrade meson mako

ensure_min() {
  # ensure_min <module> <min_version>
  local mod="$1" min="$2" cur
  cur=$(python3 -c "import $mod; print($mod.__version__)" 2>/dev/null || echo "0")
  if [[ "$(printf '%s\n%s' "$cur" "$min" | sort -V | head -n1)" != "$min" ]]; then
    pip3 install --break-system-packages --ignore-installed "$mod"
  fi
}
ensure_min pycparser 2.20
ensure_min packaging  21.0

# Rust + bindgen + cbindgen — Mesa needs Rust >= 1.82 for rusticl, NAK, and
# nouveau NIL. Skip the rustup install if the system already has it.
if ! rustc --version 2>/dev/null | grep -qE '1\.(8[2-9]|9[0-9]|[0-9]{3})'; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  source "$HOME/.cargo/env"
fi
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"
command -v bindgen  >/dev/null || cargo install bindgen-cli
command -v cbindgen >/dev/null || cargo install cbindgen

GALLIUM="llvmpipe,softpipe,virgl"
VULKAN=""

# Nouveau (open-source NVIDIA driver) is intentionally excluded — none of the
# AstralEmu handhelds run NVIDIA discrete GPUs. Switch (Tegra X1) uses the
# proprietary nvgpu downstream stack from L4T, not nouveau. Building nouveau
# also currently breaks Mesa 26.x because its Rust bindgen step doesn't
# resolve C11 atomic types in nouveau_bo.h ("atomic_uint_fast32_t" not found).
if $IS_X86; then
  GALLIUM="$GALLIUM,radeonsi,iris,crocus,zink"
  VULKAN="amd,intel,intel_hasvk,swrast"
fi

if $IS_ARM; then
  GALLIUM="$GALLIUM,panfrost,lima,v3d,vc4,freedreno,etnaviv,zink"
  VULKAN="broadcom,freedreno,panfrost,swrast"
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
