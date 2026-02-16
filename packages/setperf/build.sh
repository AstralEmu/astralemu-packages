#!/bin/bash
# Build script for setperf package (intermediate format)
set -e

VERSION="1.0.0"
PKG_NAME="setperf"
ARCH="arm64"
PKG_DIR="/tmp/${PKG_NAME}_${VERSION}_${ARCH}"

# Create intermediate structure
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/root/usr/bin"
mkdir -p "$PKG_DIR/meta"

# Install binary
cp setperf "$PKG_DIR/root/usr/bin/"
chmod +x "$PKG_DIR/root/usr/bin/setperf"

# Create metadata
echo "$PKG_NAME" > "$PKG_DIR/meta/name"
echo "$VERSION" > "$PKG_DIR/meta/version"
echo "$ARCH" > "$PKG_DIR/meta/arch"
echo "Nintendo Switch performance tuning wrapper - Applies performance settings before launching games and restores them after. Designed for L4T Linux on Nintendo Switch." > "$PKG_DIR/meta/description"
echo "AstralEmu <noreply@astralemu.github.io>" > "$PKG_DIR/meta/maintainer"
echo "deb" > "$PKG_DIR/meta/source_format"
echo "noble" > "$PKG_DIR/meta/source_distro"
echo "utils" > "$PKG_DIR/meta/section"
echo "optional" > "$PKG_DIR/meta/priority"
echo "bash" > "$PKG_DIR/meta/depends"

# Build intermediate tar
tar cf "${PKG_NAME}_${VERSION}_${ARCH}.pkg.tar" -C "$PKG_DIR" meta root

echo "Package built: ${PKG_NAME}_${VERSION}_${ARCH}.pkg.tar"
