#!/bin/bash
# kernel-astralemu — single-build noarch meta-package generator.
#
# Runs ONCE per CI run (regardless of build_target — its arch=all output
# is identical for every host arch) and emits ONE .pkg.tar per device by
# iterating devices.yml directly. The build script reads device list from
# devices.yml rather than relying on TARGET_DEVICES so it doesn't depend on
# which build_target the orchestrator picked.
#
# Resolution rules per device:
#   - kernel flavor = build_target (kernel-amd64 / kernel-arm64-modern /
#     kernel-arm64-legacy), with the Switch (l4t) special-cased to
#     kernel-tegra-x1 because mainline 6.x can't drive its GPU.
#   - dtbs are arm-only.
#   - firmware deps come from firmware_for_device() — currently disabled
#     until astralemu-firmware-* packages are built (see comment below).
set -euo pipefail

cd /workspace

DEVICES_YML="${ASTRALEMU_DEVICES_YML:-/workspace/devices.yml}"

# Per-device vendor firmware dep. Empty entry / unmatched device = none.
#
# DISABLED until the astralemu-firmware-<vendor> packages are built. None of
# `astralemu-firmware-tegra` / `-amd-handheld` / `-rockchip` / `-amlogic` /
# `-allwinner` / `-qualcomm` / `-intel-meteorlake` exist in packages/ yet —
# referencing them here would make kernel-astralemu unsatisfiable on every
# device that has a non-empty mapping. Restore the per-device map below
# (cf. docs/kernel-integration-plan.md "Mapping firmware par vendor")
# once the firmware packages are committed.
firmware_for_device() {
  case "$1" in
    # l4t)                       echo "astralemu-firmware-tegra" ;;
    # x86-v3|x86-v4|ayn-loki|steam-deck-lcd|steam-deck-oled|gpd-win|rog-ally|legion-go|ayaneo|onexplayer)
    #                            echo "astralemu-firmware-amd-handheld" ;;
    # anbernic-rg35xx-h)         echo "astralemu-firmware-allwinner" ;;
    # anbernic-rg35xx-orig|powkiddy-rk3566|anbernic-rg406|orange-pi-5)
    #                            echo "astralemu-firmware-rockchip" ;;
    # anbernic-rg-arc|odroid-go-super)
    #                            echo "astralemu-firmware-amlogic" ;;
    # retroid-pocket-5|retroid-pocket-6|ayn-thor)
    #                            echo "astralemu-firmware-qualcomm" ;;
    # msi-claw)                  echo "astralemu-firmware-intel-meteorlake" ;;
    *) ;;
  esac
}

HASH_TAG="${SHORT:-${COMMIT:0:7}}"
HASH_TAG="${HASH_TAG:-0000000}"
VERSION="1.0.0+${HASH_TAG}"

# Iterate every device in devices.yml. Order doesn't matter — each one
# becomes a self-contained .pkg.tar.
DEVICE_IDS=$(yq -r '.devices[].id' "$DEVICES_YML")
emitted=0
for DEVICE_ID in $DEVICE_IDS; do
  BUILD_TARGET=$(yq -r ".devices[] | select(.id == \"$DEVICE_ID\") | .build_target" "$DEVICES_YML")
  [[ -n "$BUILD_TARGET" && "$BUILD_TARGET" != "null" ]] || {
    echo "WARN: device '$DEVICE_ID' has no build_target, skipping" >&2
    continue
  }

  # Switch L4T can't run kernel-arm64-legacy (NVIDIA nvgpu downstream-only,
  # never ported to mainline). Falls back to kernel-tegra-x1 (4.9, NaGaa95).
  case "$DEVICE_ID" in
    l4t) KFLAVOR="tegra-x1" ;;
    *)   KFLAVOR="$BUILD_TARGET" ;;
  esac

  case "$BUILD_TARGET" in
    amd64)   HAS_DTBS=false ;;
    arm64-*) HAS_DTBS=true  ;;
    *) echo "WARN: unsupported build_target '$BUILD_TARGET' for $DEVICE_ID, skipping" >&2; continue ;;
  esac

  PKG=/tmp/pkg-meta-$DEVICE_ID
  rm -rf "$PKG"
  mkdir -p "$PKG/meta" "$PKG/root"

  NAME="kernel-astralemu-${DEVICE_ID}"

  echo "$NAME"            > "$PKG/meta/name"
  echo "$VERSION"         > "$PKG/meta/version"
  echo "all"              > "$PKG/meta/arch"
  cat > "$PKG/meta/description" <<DESC
AstralEmu kernel + modules + dtbs + firmware + setperf bundle for
${DEVICE_ID} (kernel flavor ${KFLAVOR}). Single 'apt install' / 'dnf
install' / 'pacman -S' shortcut that pulls every device-specific piece
of the AstralEmu stack at once.
DESC
  echo "kernel"           > "$PKG/meta/section"
  echo "optional"         > "$PKG/meta/priority"

  DEPS="$PKG/meta/depends"
  {
    echo "kernel-${KFLAVOR}"
    echo "kernel-modules-${KFLAVOR}"
    if [[ "$HAS_DTBS" == "true" ]]; then
      echo "astralemu-dtbs-${KFLAVOR}"
    fi
    echo "setperf"
    echo "astralemu-deps-repo"
    fw=$(firmware_for_device "$DEVICE_ID")
    [[ -n "$fw" ]] && echo "$fw"
  } > "$DEPS"

  bash /workspace/scripts/finalize-meta.sh "$PKG/meta"

  tar cf "/workspace/${NAME}_${VERSION}_all.pkg.tar" -C "$PKG" meta root
  emitted=$((emitted + 1))
done

echo "Generated $emitted kernel-astralemu meta-packages (version $VERSION)"
ls -lh /workspace/kernel-astralemu-*.pkg.tar 2>/dev/null
echo "completed" > /workspace/build-status
