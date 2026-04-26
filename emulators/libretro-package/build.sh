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
  # The OS builder reads emulators.yml and resolves package names by emu_id,
  # which is "libretro-package" here (not the published "libretro-cores"
  # basename). Emit a second set of aliases so apt install libretro-package-l4t
  # works even though the actual package is libretro-cores-arm64-legacy.
  bash /workspace/scripts/emit-aliases.sh libretro-package pkg/meta
  # Suffix the build hash so the deb version bumps whenever build.sh or its
  # config entry changes — otherwise pkg_exists_in_repo keeps the old deb.
  echo "1.0.0+${SHORT:-0000000}" > pkg/meta/version
  echo "${TARGET_ARCH}" > pkg/meta/arch
  echo "Libretro cores for RetroArch (${TARGET_ID} build) - All standard libretro cores compiled for ${TARGET_ID}." > pkg/meta/description
  echo "games" > pkg/meta/section
  echo "optional" > pkg/meta/priority
  cat > pkg/meta/depends << DEPS
libc6
zlib1g
libjemalloc2
DEPS

  bash /workspace/scripts/finalize-meta.sh pkg/meta
  tar cf "/workspace/libretro-cores-${TARGET_ID}_1.0.0_${TARGET_ARCH}.pkg.tar" -C pkg meta root
  echo "completed" > /workspace/build-status
else
  echo "No cores found"
fi
