#!/bin/bash
set -e

TARGET_ID="${TARGET_ID}"
TARGET_ARCH="${TARGET_ARCH}"

cd /workspace

if find cores/ -name '*.so' 2>/dev/null | grep -q .; then
  mkdir -p pkg/root/usr/lib/libretro pkg/meta
  find cores/ -name '*.so' -exec cp {} pkg/root/usr/lib/libretro/ \;

  echo "libretro-cores-${TARGET_ID}" > pkg/meta/name
  bash /workspace/scripts/emit-aliases.sh libretro-cores pkg/meta
  echo "1.0.0" > pkg/meta/version
  echo "${TARGET_ARCH}" > pkg/meta/arch
  echo "Libretro cores for RetroArch (${TARGET_ID} build) - All standard libretro cores compiled for ${TARGET_ID}." > pkg/meta/description
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

  tar cf "/workspace/libretro-cores-${TARGET_ID}_1.0.0_${TARGET_ARCH}.pkg.tar" -C pkg meta root
  echo "completed" > /workspace/build-status
else
  echo "No cores found"
fi
