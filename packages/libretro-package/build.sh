#!/bin/bash
set -e

DEVICE_ID="${DEVICE_ID}"
DEVICE_ARCH="${DEVICE_ARCH}"

cd /workspace

if ls cores/*.so 1>/dev/null 2>&1; then
  mkdir -p pkg/root/usr/lib/libretro pkg/meta
  cp cores/*.so pkg/root/usr/lib/libretro/

  echo "libretro-cores-${DEVICE_ID}" > pkg/meta/name
  echo "1.0.0" > pkg/meta/version
  echo "${DEVICE_ARCH}" > pkg/meta/arch
  echo "Libretro cores for RetroArch (${DEVICE_ID} build) - All standard libretro cores compiled for ${DEVICE_ID}." > pkg/meta/description
  echo "AstralEmu <noreply@astralemu.github.io>" > pkg/meta/maintainer
  echo "deb" > pkg/meta/source_format
  echo "noble" > pkg/meta/source_distro
  echo "games" > pkg/meta/section
  echo "optional" > pkg/meta/priority
  cat > pkg/meta/depends << DEPS
libc6
zlib1g
libjemalloc2
DEPS

  tar cf "/workspace/libretro-cores-${DEVICE_ID}_1.0.0_${DEVICE_ARCH}.pkg.tar" -C pkg meta root
  echo "completed" > /workspace/build-status
else
  echo "No cores found"
fi
