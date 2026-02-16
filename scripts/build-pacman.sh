#!/bin/bash
# build-pacman.sh — Convert a .deb package to a Pacman .pkg.tar.zst
# Usage: ./build-pacman.sh <input.deb> <output-dir>
set -e

DEB="$1"
OUTDIR="${2:-.}"

if [[ -z "$DEB" || ! -f "$DEB" ]]; then
  echo "Usage: $0 <input.deb> [output-dir]" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

# Extract metadata and files from .deb
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

dpkg-deb -e "$DEB" "$TMPDIR/control"
dpkg-deb -x "$DEB" "$TMPDIR/pkg"

PKG_NAME=$(grep -m1 '^Package:' "$TMPDIR/control/control" | awk '{print $2}')
PKG_VERSION=$(grep -m1 '^Version:' "$TMPDIR/control/control" | awk '{print $2}')
PKG_ARCH=$(grep -m1 '^Architecture:' "$TMPDIR/control/control" | awk '{print $2}')
PKG_DESC=$(grep -m1 '^Description:' "$TMPDIR/control/control" | sed 's/^Description: //')
PKG_MAINTAINER=$(grep -m1 '^Maintainer:' "$TMPDIR/control/control" | sed 's/^Maintainer: //')

# Map Debian arch to Pacman arch
case "$PKG_ARCH" in
  arm64)  PAC_ARCH="aarch64" ;;
  amd64)  PAC_ARCH="x86_64" ;;
  *)      PAC_ARCH="$PKG_ARCH" ;;
esac

# Clean version (remove epoch, replace - with .)
PAC_VERSION=$(echo "$PKG_VERSION" | sed 's/^[0-9]*://; s/-/./g')

# Compute installed size in bytes
INSTALL_SIZE=$(du -sb "$TMPDIR/pkg" | awk '{print $1}')

# Build date
BUILD_DATE=$(date +%s)

# Generate .PKGINFO
cat > "$TMPDIR/pkg/.PKGINFO" << PKGINFO
pkgname = $PKG_NAME
pkgver = ${PAC_VERSION}-1
pkgdesc = $PKG_DESC
url = https://github.com/AstralEmu/astralemu-packages
builddate = $BUILD_DATE
packager = $PKG_MAINTAINER
size = $INSTALL_SIZE
arch = $PAC_ARCH
PKGINFO

# Generate .MTREE (file integrity manifest)
cd "$TMPDIR/pkg"
# Use bsdtar for proper .MTREE generation
if command -v bsdtar &>/dev/null; then
  LANG=C bsdtar -czf .MTREE --format=mtree \
    --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
    .PKGINFO $(find . -not -name '.PKGINFO' -not -name '.MTREE' -not -path '.' | sort)
fi

# Create .pkg.tar.zst
PKG_FILENAME="${PKG_NAME}-${PAC_VERSION}-1-${PAC_ARCH}.pkg.tar.zst"
# Include .PKGINFO first, then .MTREE, then all files
tar --zstd -cf "$OUTDIR/$PKG_FILENAME" \
  .PKGINFO \
  $(test -f .MTREE && echo .MTREE) \
  --exclude='.PKGINFO' --exclude='.MTREE' \
  *

echo "Pacman package built: $OUTDIR/$PKG_FILENAME"
