#!/bin/bash
# build-rpm.sh — Convert a .deb package to .rpm
# Usage: ./build-rpm.sh <input.deb> <output-dir>
set -e

DEB="$1"
OUTDIR="${2:-.}"

if [[ -z "$DEB" || ! -f "$DEB" ]]; then
  echo "Usage: $0 <input.deb> [output-dir]" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

# Extract metadata from .deb control file
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

dpkg-deb -e "$DEB" "$TMPDIR/control"
dpkg-deb -x "$DEB" "$TMPDIR/root"

PKG_NAME=$(grep -m1 '^Package:' "$TMPDIR/control/control" | awk '{print $2}')
PKG_VERSION=$(grep -m1 '^Version:' "$TMPDIR/control/control" | awk '{print $2}')
PKG_ARCH=$(grep -m1 '^Architecture:' "$TMPDIR/control/control" | awk '{print $2}')
PKG_DESC=$(grep -m1 '^Description:' "$TMPDIR/control/control" | sed 's/^Description: //')
PKG_MAINTAINER=$(grep -m1 '^Maintainer:' "$TMPDIR/control/control" | sed 's/^Maintainer: //')

# Map Debian arch to RPM arch
case "$PKG_ARCH" in
  arm64)  RPM_ARCH="aarch64" ;;
  amd64)  RPM_ARCH="x86_64" ;;
  *)      RPM_ARCH="$PKG_ARCH" ;;
esac

# Clean version for RPM (no colons or hyphens in upstream version)
RPM_VERSION=$(echo "$PKG_VERSION" | tr ':~' '..' | sed 's/-/./g')

# Setup rpmbuild tree
RPMBUILD="$TMPDIR/rpmbuild"
mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,BUILDROOT}

# Create spec file
cat > "$RPMBUILD/SPECS/$PKG_NAME.spec" << SPEC
Name:    $PKG_NAME
Version: $RPM_VERSION
Release: 1
Summary: $PKG_DESC
License: GPL
Packager: $PKG_MAINTAINER
AutoReqProv: no

%description
$PKG_DESC

%install
cp -a $TMPDIR/root/* %{buildroot}/

%files
$(cd "$TMPDIR/root" && find . -type f -o -type l | sed 's|^\.|/|')
SPEC

# Build RPM
rpmbuild --define "_topdir $RPMBUILD" \
         --define "_rpmdir $OUTDIR" \
         --target "$RPM_ARCH" \
         -bb "$RPMBUILD/SPECS/$PKG_NAME.spec" 2>/dev/null

# Move RPM to output dir root (rpmbuild puts it in arch subdir)
find "$OUTDIR" -name '*.rpm' -path "*/$RPM_ARCH/*" -exec mv {} "$OUTDIR/" \; 2>/dev/null
rmdir "$OUTDIR/$RPM_ARCH" 2>/dev/null || true

echo "RPM built: $OUTDIR/${PKG_NAME}-${RPM_VERSION}-1.${RPM_ARCH}.rpm"
