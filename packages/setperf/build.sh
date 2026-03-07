#!/bin/bash
# Build script for setperf package (intermediate format)
set -e

DEVICE_ID="${DEVICE_ID}"
DEVICE_ARCH="${DEVICE_ARCH}"

cd /workspace

DEVICE_DIR="/workspace/packages/setperf/$DEVICE_ID"

if [[ ! -f "$DEVICE_DIR/setperf" ]]; then
  echo "No setperf script for device $DEVICE_ID, skipping"
  exit 0
fi

VERSION="1.0.0"
PKG_NAME="setperf"
PKG_DIR="/tmp/${PKG_NAME}_${VERSION}_${DEVICE_ARCH}"

# Create intermediate structure
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/root/usr/bin"
mkdir -p "$PKG_DIR/meta"

# Install binary
cp "$DEVICE_DIR/setperf" "$PKG_DIR/root/usr/bin/"
chmod +x "$PKG_DIR/root/usr/bin/setperf"

# Create metadata
echo "$PKG_NAME" > "$PKG_DIR/meta/name"
echo "$VERSION" > "$PKG_DIR/meta/version"
echo "$DEVICE_ARCH" > "$PKG_DIR/meta/arch"
echo "Performance tuning wrapper for ${DEVICE_ID}" > "$PKG_DIR/meta/description"
echo "AstralEmu <noreply@astralemu.github.io>" > "$PKG_DIR/meta/maintainer"
echo "deb" > "$PKG_DIR/meta/source_format"
echo "noble" > "$PKG_DIR/meta/source_distro"
echo "utils" > "$PKG_DIR/meta/section"
echo "optional" > "$PKG_DIR/meta/priority"
echo "bash" > "$PKG_DIR/meta/depends"

# Build intermediate tar
tar cf "/workspace/${PKG_NAME}-${DEVICE_ID}_${VERSION}_${DEVICE_ARCH}.pkg.tar" -C "$PKG_DIR" meta root
echo "completed" > /workspace/build-status
