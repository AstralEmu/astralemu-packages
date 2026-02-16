#!/bin/bash
# pkg-build-pacman.sh — Build a .pkg.tar.zst from the intermediate format
# Usage: ./pkg-build-pacman.sh <intermediate-dir> <output-dir> [--dep-map <dep-map.conf>]
set -euo pipefail

INTDIR="$1"
OUTDIR="$2"
DEP_MAP=""

shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dep-map) DEP_MAP="$2"; shift 2 ;;
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

# Map arch
case "$PKG_ARCH" in
  aarch64) PAC_ARCH="aarch64" ;;
  x86_64)  PAC_ARCH="x86_64" ;;
  *)       PAC_ARCH="$PKG_ARCH" ;;
esac

# Clean version (remove epoch, replace - with .)
PAC_VERSION=$(echo "$PKG_VERSION" | sed 's/^[0-9]*://; s/-/./g')

# Map dependency name to pacman name
map_dep_to_pacman() {
  local dep="$1"
  local source_format
  source_format=$(cat "$INTDIR/meta/source_format")

  # If already pacman, keep as-is
  if [[ "$source_format" == "pacman" ]]; then
    echo "$dep"
    return
  fi

  if [[ -n "$DEP_MAP" && -f "$DEP_MAP" ]]; then
    local mapped=""
    if [[ "$source_format" == "deb" ]]; then
      mapped=$(grep "^${dep} " "$DEP_MAP" | head -1 | grep -oP 'pac:\K[^,\s]+' | tr -d ' ')
    elif [[ "$source_format" == "rpm" ]]; then
      mapped=$(grep "rpm:${dep}" "$DEP_MAP" | head -1 | grep -oP 'pac:\K[^,\s]+' | tr -d ' ')
    fi
    if [[ -n "$mapped" ]]; then
      echo "$mapped"
      return
    fi
  fi

  echo "$dep"
}

# Build in temp dir
BUILDDIR=$(mktemp -d)
trap 'rm -rf "$BUILDDIR"' EXIT

cp -a "$INTDIR/root"/* "$BUILDDIR/" 2>/dev/null || true

# Compute installed size in bytes
INSTALL_SIZE=$(du -sb "$BUILDDIR" | cut -f1)
BUILD_DATE=$(date +%s)

# Generate .PKGINFO
cat > "$BUILDDIR/.PKGINFO" << EOF
pkgname = $PKG_NAME
pkgver = ${PAC_VERSION}-1
pkgdesc = $PKG_DESC
url = https://github.com/AstralEmu/astralemu-packages
builddate = $BUILD_DATE
packager = $PKG_MAINTAINER
size = $INSTALL_SIZE
arch = $PAC_ARCH
EOF

# Add depends
if [[ -s "$INTDIR/meta/depends" ]]; then
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    pac_dep=$(map_dep_to_pacman "$dep")
    echo "depend = $pac_dep" >> "$BUILDDIR/.PKGINFO"
  done < "$INTDIR/meta/depends"
fi

# Optional provides/conflicts/replaces
if [[ -s "$INTDIR/meta/provides" ]]; then
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    echo "provides = $p" >> "$BUILDDIR/.PKGINFO"
  done < "$INTDIR/meta/provides"
fi
if [[ -s "$INTDIR/meta/conflicts" ]]; then
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    echo "conflict = $c" >> "$BUILDDIR/.PKGINFO"
  done < "$INTDIR/meta/conflicts"
fi
if [[ -s "$INTDIR/meta/replaces" ]]; then
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    echo "replaces = $r" >> "$BUILDDIR/.PKGINFO"
  done < "$INTDIR/meta/replaces"
fi

# Generate .INSTALL from scripts
HAS_INSTALL=false
INSTALL_FILE="$BUILDDIR/.INSTALL"

write_install_func() {
  local func_name="$1"
  local script_file="$2"
  if [[ -f "$script_file" ]]; then
    HAS_INSTALL=true
    echo "${func_name}() {" >> "$INSTALL_FILE"
    # Strip shebang if present
    sed '/^#!\/bin\//d' "$script_file" >> "$INSTALL_FILE"
    echo "}" >> "$INSTALL_FILE"
    echo "" >> "$INSTALL_FILE"
  fi
}

> "$INSTALL_FILE"
write_install_func "pre_install"  "$INTDIR/meta/scripts/preinst"
write_install_func "post_install" "$INTDIR/meta/scripts/postinst"
write_install_func "pre_remove"   "$INTDIR/meta/scripts/prerm"
write_install_func "post_remove"  "$INTDIR/meta/scripts/postrm"

if [[ "$HAS_INSTALL" != "true" ]]; then
  rm -f "$INSTALL_FILE"
fi

# Generate .MTREE
cd "$BUILDDIR"
if command -v bsdtar &>/dev/null; then
  LANG=C bsdtar -czf .MTREE --format=mtree \
    --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
    .PKGINFO $(test -f .INSTALL && echo .INSTALL) \
    $(find . -not -name '.PKGINFO' -not -name '.INSTALL' -not -name '.MTREE' -not -path '.' | sort) 2>/dev/null || true
fi

# Create .pkg.tar.zst
PKG_FILENAME="${PKG_NAME}-${PAC_VERSION}-1-${PAC_ARCH}.pkg.tar.zst"

# Build file list for tar: metadata first, then content
TAR_FILES=".PKGINFO"
[[ -f .MTREE ]] && TAR_FILES="$TAR_FILES .MTREE"
[[ -f .INSTALL ]] && TAR_FILES="$TAR_FILES .INSTALL"

tar --zstd -cf "$OUTDIR/$PKG_FILENAME" \
  $TAR_FILES \
  --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.INSTALL' --exclude='.BUILDINFO' \
  * 2>/dev/null || tar --zstd -cf "$OUTDIR/$PKG_FILENAME" $TAR_FILES

echo "Pacman package built: $OUTDIR/$PKG_FILENAME"
