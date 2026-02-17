#!/bin/bash
# pkg-build-deb.sh — Build a .deb from the intermediate format
# Usage: ./pkg-build-deb.sh <intermediate-dir> <output-dir> [--dep-map <dep-map.conf>] [--target-distro <codename>]
set -euo pipefail

INTDIR="$1"
OUTDIR="$2"
DEP_MAP=""
TARGET_DISTRO=""

shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dep-map) DEP_MAP="$2"; shift 2 ;;
    --target-distro) TARGET_DISTRO="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -d "$INTDIR/meta" || ! -d "$INTDIR/root" ]]; then
  echo "ERROR: Invalid intermediate directory: $INTDIR" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

PKG_NAME=$(cat "$INTDIR/meta/name")
PKG_VERSION=$(cat "$INTDIR/meta/version")
PKG_ARCH=$(cat "$INTDIR/meta/arch")
PKG_DESC=$(cat "$INTDIR/meta/description")
PKG_MAINTAINER=$(cat "$INTDIR/meta/maintainer")
SOURCE_DISTRO=$(cat "$INTDIR/meta/source_distro" 2>/dev/null || echo "unknown")

# Map arch to deb convention
case "$PKG_ARCH" in
  aarch64) DEB_ARCH="arm64" ;;
  x86_64)  DEB_ARCH="amd64" ;;
  armhf)   DEB_ARCH="armhf" ;;
  *)       DEB_ARCH="$PKG_ARCH" ;;
esac

# Map dependency names: source format -> deb names
# If source was already deb, names stay the same
# If source was rpm/pacman, reverse-lookup from dep-map.conf
map_dep_to_deb() {
  local dep="$1"
  local source_format
  source_format=$(cat "$INTDIR/meta/source_format")

  if [[ "$source_format" == "deb" ]]; then
    echo "$dep"
    return
  fi

  if [[ -n "$DEP_MAP" && -f "$DEP_MAP" ]]; then
    local mapped=""
    if [[ "$source_format" == "rpm" ]]; then
      # Reverse lookup: find deb name where rpm:X matches
      mapped=$(grep "rpm:${dep}" "$DEP_MAP" | head -1 | cut -d'=' -f1 | tr -d ' ')
    elif [[ "$source_format" == "pacman" ]]; then
      mapped=$(grep "pac:${dep}" "$DEP_MAP" | head -1 | cut -d'=' -f1 | tr -d ' ')
    fi
    if [[ -n "$mapped" ]]; then
      echo "$mapped"
      return
    fi
  fi

  # Fallback: use as-is
  echo "$dep"
}

# Build depends line
DEPENDS=""
if [[ -s "$INTDIR/meta/depends" ]]; then
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    deb_dep=$(map_dep_to_deb "$dep")
    if [[ -n "$DEPENDS" ]]; then
      DEPENDS="$DEPENDS, $deb_dep"
    else
      DEPENDS="$deb_dep"
    fi
  done < "$INTDIR/meta/depends"
fi

# Build the deb structure
BUILDDIR=$(mktemp -d)
trap 'rm -rf "$BUILDDIR"' EXIT

cp -a "$INTDIR/root"/* "$BUILDDIR/" 2>/dev/null || true
mkdir -p "$BUILDDIR/DEBIAN"

# Generate control file
cat > "$BUILDDIR/DEBIAN/control" << EOF
Package: $PKG_NAME
Version: $PKG_VERSION
Architecture: $DEB_ARCH
Maintainer: $PKG_MAINTAINER
Description: $PKG_DESC
EOF

if [[ -n "$DEPENDS" ]]; then
  echo "Depends: $DEPENDS" >> "$BUILDDIR/DEBIAN/control"
fi

# Optional fields
for field in provides conflicts replaces; do
  if [[ -s "$INTDIR/meta/$field" ]]; then
    FIELD_UPPER=$(echo "$field" | sed 's/^./\U&/')
    VALUE=$(paste -sd', ' "$INTDIR/meta/$field")
    echo "$FIELD_UPPER: $VALUE" >> "$BUILDDIR/DEBIAN/control"
  fi
done

if [[ -s "$INTDIR/meta/section" ]]; then
  echo "Section: $(cat "$INTDIR/meta/section")" >> "$BUILDDIR/DEBIAN/control"
fi

if [[ -s "$INTDIR/meta/priority" ]]; then
  echo "Priority: $(cat "$INTDIR/meta/priority")" >> "$BUILDDIR/DEBIAN/control"
fi

# Compute installed size (in KB)
INSTALLED_SIZE=$(du -sk "$BUILDDIR" | cut -f1)
echo "Installed-Size: $INSTALLED_SIZE" >> "$BUILDDIR/DEBIAN/control"

# Copy maintainer scripts
for script in preinst postinst prerm postrm; do
  if [[ -f "$INTDIR/meta/scripts/$script" ]]; then
    cp "$INTDIR/meta/scripts/$script" "$BUILDDIR/DEBIAN/$script"
    chmod 755 "$BUILDDIR/DEBIAN/$script"
  fi
done

# Build the .deb (strip epoch from filename — colons are invalid on some filesystems)
DEB_VERSION=$(echo "$PKG_VERSION" | sed 's/^[0-9]*://')
DEB_FILE="${PKG_NAME}_${DEB_VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build --root-owner-group "$BUILDDIR" "$OUTDIR/$DEB_FILE"

echo "DEB built: $OUTDIR/$DEB_FILE"
