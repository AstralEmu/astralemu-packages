#!/bin/bash
# Build script for setperf package
set -e

VERSION="1.0.0"
PKG_NAME="setperf"
PKG_DIR="/tmp/${PKG_NAME}_${VERSION}_arm64"

# Create package structure
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/usr/bin"
mkdir -p "$PKG_DIR/DEBIAN"

# Install binary
cp setperf "$PKG_DIR/usr/bin/"
chmod +x "$PKG_DIR/usr/bin/setperf"

# Create control file
cat > "$PKG_DIR/DEBIAN/control" << EOF
Package: setperf
Version: ${VERSION}
Architecture: arm64
Maintainer: AstralEmu <noreply@astralemu.github.io>
Depends: bash
Section: utils
Priority: optional
Description: Nintendo Switch performance tuning wrapper
 Applies performance settings before launching games and restores them after.
 Designed for L4T Linux on Nintendo Switch.
EOF

# Build package
dpkg-deb --build "$PKG_DIR" "${PKG_NAME}_${VERSION}_arm64.deb"

echo "Package built: ${PKG_NAME}_${VERSION}_arm64.deb"
