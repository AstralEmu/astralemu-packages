#!/bin/bash
# Build script for setperf package (intermediate format)
set -e

TARGET_ID="${TARGET_ID}"
TARGET_ARCH="${TARGET_ARCH}"

cd /workspace

TARGET_DIR="/workspace/packages/setperf/$TARGET_ID"
SETPERF_SCRIPT="$TARGET_DIR/setperf"

# packages.yml flag payload_optional=true means: build for every device
# even without a hand-tuned setperf script. Devices without one ship a
# no-op binary so that meta-packages (kernel-astralemu-<device>) can
# always resolve their hard dep on `setperf`.
if [[ ! -f "$SETPERF_SCRIPT" ]]; then
  echo "No setperf script for device $TARGET_ID — emitting no-op fallback"
  SETPERF_SCRIPT=$(mktemp)
  cat > "$SETPERF_SCRIPT" <<'NOOP'
#!/bin/bash
# AstralEmu setperf — no-op fallback.
#
# This device does not (yet) have a hand-tuned governor / clock / pinning
# profile. Calling setperf is a no-op until per-device tuning ships under
# packages/setperf/<device-id>/setperf in astralemu-packages.
exit 0
NOOP
  chmod +x "$SETPERF_SCRIPT"
fi

# Suffix the build hash so the deb version bumps when the script changes
# (otherwise pkg_exists_in_repo skips republishing).
VERSION="1.0.0+${SHORT:-0000000}"
PKG_NAME="setperf"
PKG_DIR="/tmp/${PKG_NAME}_${VERSION}_${TARGET_ARCH}"

# Create intermediate structure
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/root/usr/bin"
mkdir -p "$PKG_DIR/meta"

# Install binary (either the device-specific script or the no-op fallback)
cp "$SETPERF_SCRIPT" "$PKG_DIR/root/usr/bin/setperf"
chmod +x "$PKG_DIR/root/usr/bin/setperf"

# Create metadata
echo "$PKG_NAME" > "$PKG_DIR/meta/name"
echo "$VERSION" > "$PKG_DIR/meta/version"
echo "$TARGET_ARCH" > "$PKG_DIR/meta/arch"
echo "Performance tuning wrapper for ${TARGET_ID}" > "$PKG_DIR/meta/description"
echo "utils" > "$PKG_DIR/meta/section"
echo "optional" > "$PKG_DIR/meta/priority"
echo "bash" > "$PKG_DIR/meta/depends"

# Build intermediate tar
bash /workspace/scripts/finalize-meta.sh "$PKG_DIR/meta"
tar cf "/workspace/${PKG_NAME}-${TARGET_ID}_${VERSION}_${TARGET_ARCH}.pkg.tar" -C "$PKG_DIR" meta root
echo "completed" > /workspace/build-status
