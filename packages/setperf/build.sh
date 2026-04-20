#!/bin/bash
# Build script for setperf package (intermediate format)
set -e

TARGET_ID="${TARGET_ID}"
TARGET_ARCH="${TARGET_ARCH}"

cd /workspace

TARGET_DIR="/workspace/packages/setperf/$TARGET_ID"

if [[ ! -f "$TARGET_DIR/setperf" ]]; then
  echo "No setperf script for device $TARGET_ID, skipping"
  exit 0
fi

VERSION="1.0.0"
PKG_NAME="setperf"
PKG_DIR="/tmp/${PKG_NAME}_${VERSION}_${TARGET_ARCH}"

# Create intermediate structure
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/root/usr/bin"
mkdir -p "$PKG_DIR/meta"

# Install binary
cp "$TARGET_DIR/setperf" "$PKG_DIR/root/usr/bin/"
chmod +x "$PKG_DIR/root/usr/bin/setperf"

# Create metadata
echo "$PKG_NAME" > "$PKG_DIR/meta/name"
echo "$VERSION" > "$PKG_DIR/meta/version"
echo "$TARGET_ARCH" > "$PKG_DIR/meta/arch"
echo "Performance tuning wrapper for ${TARGET_ID}" > "$PKG_DIR/meta/description"
echo "AstralEmu <noreply@astralemu.github.io>" > "$PKG_DIR/meta/maintainer"
echo "deb" > "$PKG_DIR/meta/source_format"
echo "${SOURCE_DISTRO:-noble}" > "$PKG_DIR/meta/source_distro"
echo "utils" > "$PKG_DIR/meta/section"
echo "optional" > "$PKG_DIR/meta/priority"
echo "bash" > "$PKG_DIR/meta/depends"

# Build intermediate tar
tar cf "/workspace/${PKG_NAME}-${TARGET_ID}_${VERSION}_${TARGET_ARCH}.pkg.tar" -C "$PKG_DIR" meta root
echo "completed" > /workspace/build-status
