#!/bin/bash
# pkg-build-pacman.sh — Build a .pkg.tar.zst from the intermediate format
# Usage: ./pkg-build-pacman.sh <intermediate-dir> <output-dir> [--dep-map <dep-map.conf>]
#
# Supports any source format: deb, rpm, pacman → pacman
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cross-pkg-helpers.sh
source "$SCRIPT_DIR/cross-pkg-helpers.sh"

INTDIR="$1"
OUTDIR="$2"
# Convert to absolute paths (script does cd later, breaking relative paths)
[[ "$INTDIR" != /* ]] && INTDIR="$(cd "$INTDIR" && pwd)"
mkdir -p "$OUTDIR"
[[ "$OUTDIR" != /* ]] && OUTDIR="$(cd "$OUTDIR" && pwd)"
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

PKG_NAME=$(cat "$INTDIR/meta/name")
PKG_VERSION=$(cat "$INTDIR/meta/version")
PKG_ARCH=$(cat "$INTDIR/meta/arch")
PKG_DESC=$(cat "$INTDIR/meta/description")
PKG_MAINTAINER=$(cat "$INTDIR/meta/maintainer")
SOURCE_FORMAT=$(cat "$INTDIR/meta/source_format")

# Map arch
case "$PKG_ARCH" in
  aarch64)        PAC_ARCH="aarch64" ;;
  x86_64)         PAC_ARCH="x86_64" ;;
  armhf)          PAC_ARCH="armv7h" ;;
  all|noarch|any) PAC_ARCH="any" ;;
  *)              PAC_ARCH="$PKG_ARCH" ;;
esac

# Clean version (remove epoch, strip +suffix, replace - with .)
PAC_VERSION=$(echo "$PKG_VERSION" | sed 's/+[^-]*//; s/^[0-9]*://; s/-/./g')

# Map dependency name to pacman name
map_dep_to_pacman() {
  local dep="$1"

  if [[ "$SOURCE_FORMAT" == "pacman" ]]; then
    echo "$dep"
    return
  fi

  if [[ -n "$DEP_MAP" && -f "$DEP_MAP" ]]; then
    local mapped=""
    if [[ "$SOURCE_FORMAT" == "deb" ]]; then
      mapped=$(grep "^${dep} " "$DEP_MAP" | head -1 | grep -oP 'pac:\K[^,\s]+' || true)
    elif [[ "$SOURCE_FORMAT" == "rpm" ]]; then
      mapped=$(grep " rpm:${dep}" "$DEP_MAP" | head -1 | grep -oP 'pac:\K[^,\s]+' || true)
    fi
    if [[ -n "$mapped" ]]; then
      echo "$mapped"
      return
    fi
  fi

  echo "$dep"
}

# ========================================================================
# Relocate library paths (deb multiarch, lib64, /lib merge)
# ========================================================================
if [[ "$SOURCE_FORMAT" != "pacman" ]]; then
  relocate_lib_paths "$INTDIR/root" "/usr/lib"
fi

# ========================================================================

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

# Add backup (conffiles) entries — pacman uses relative paths without leading /
if [[ -s "$INTDIR/meta/conffiles" ]]; then
  while IFS= read -r cf; do
    [[ -z "$cf" ]] && continue
    echo "backup = ${cf#/}" >> "$BUILDDIR/.PKGINFO"
  done < "$INTDIR/meta/conffiles"
fi

# ========================================================================
# Generate .INSTALL from translated scripts + systemd handling
# Handles all source formats: deb, rpm (with $1 splitting), pacman (direct)
# ========================================================================
INSTALL_FILE="$BUILDDIR/.INSTALL"
HAS_INSTALL=false

PRE_INSTALL=""
POST_INSTALL=""
PRE_REMOVE=""
POST_REMOVE=""
PRE_UPGRADE=""
POST_UPGRADE=""

# --- RPM source: split $1 conditionals into install vs upgrade ---
# RPM %pre uses $1=1 (install) and $1=2 (upgrade)
# RPM %preun uses $1=0 (uninstall) and $1=1 (before upgrade)
# We call translate_script twice per script with different simulated $1 values.
if [[ "$SOURCE_FORMAT" == "rpm" ]]; then
  if [[ -f "$INTDIR/meta/scripts/preinst" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/preinst" "rpm" "pacman" 1)
    [[ -n "$T" ]] && PRE_INSTALL+="$T"$'\n'
    T=$(translate_script "$INTDIR/meta/scripts/preinst" "rpm" "pacman" 2)
    [[ -n "$T" ]] && PRE_UPGRADE+="$T"$'\n'
  fi
  if [[ -f "$INTDIR/meta/scripts/postinst" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/postinst" "rpm" "pacman" 1)
    [[ -n "$T" ]] && POST_INSTALL+="$T"$'\n'
    T=$(translate_script "$INTDIR/meta/scripts/postinst" "rpm" "pacman" 2)
    [[ -n "$T" ]] && POST_UPGRADE+="$T"$'\n'
  fi
  if [[ -f "$INTDIR/meta/scripts/prerm" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/prerm" "rpm" "pacman" 0)
    [[ -n "$T" ]] && PRE_REMOVE+="$T"$'\n'
    T=$(translate_script "$INTDIR/meta/scripts/prerm" "rpm" "pacman" 1)
    [[ -n "$T" ]] && PRE_UPGRADE+="$T"$'\n'
  fi
  if [[ -f "$INTDIR/meta/scripts/postrm" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/postrm" "rpm" "pacman" 0)
    [[ -n "$T" ]] && POST_REMOVE+="$T"$'\n'
    T=$(translate_script "$INTDIR/meta/scripts/postrm" "rpm" "pacman" 1)
    [[ -n "$T" ]] && POST_UPGRADE+="$T"$'\n'
  fi

# --- Deb source: same content for install and upgrade (configure runs on both) ---
elif [[ "$SOURCE_FORMAT" == "deb" ]]; then
  if [[ -f "$INTDIR/meta/scripts/preinst" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/preinst" "deb" "pacman")
    [[ -n "$T" ]] && PRE_INSTALL+="$T"$'\n' && PRE_UPGRADE+="$T"$'\n'
  fi
  if [[ -f "$INTDIR/meta/scripts/postinst" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/postinst" "deb" "pacman")
    [[ -n "$T" ]] && POST_INSTALL+="$T"$'\n' && POST_UPGRADE+="$T"$'\n'
  fi
  if [[ -f "$INTDIR/meta/scripts/prerm" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/prerm" "deb" "pacman")
    [[ -n "$T" ]] && PRE_REMOVE+="$T"$'\n'
  fi
  if [[ -f "$INTDIR/meta/scripts/postrm" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/postrm" "deb" "pacman")
    [[ -n "$T" ]] && POST_REMOVE+="$T"$'\n'
  fi

# --- Pacman source: use scripts directly + extracted upgrade functions ---
else
  if [[ -f "$INTDIR/meta/scripts/preinst" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/preinst" "pacman" "pacman")
    [[ -n "$T" ]] && PRE_INSTALL+="$T"$'\n'
  fi
  if [[ -f "$INTDIR/meta/scripts/postinst" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/postinst" "pacman" "pacman")
    [[ -n "$T" ]] && POST_INSTALL+="$T"$'\n'
  fi
  if [[ -f "$INTDIR/meta/scripts/prerm" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/prerm" "pacman" "pacman")
    [[ -n "$T" ]] && PRE_REMOVE+="$T"$'\n'
  fi
  if [[ -f "$INTDIR/meta/scripts/postrm" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/postrm" "pacman" "pacman")
    [[ -n "$T" ]] && POST_REMOVE+="$T"$'\n'
  fi
  if [[ -f "$INTDIR/meta/scripts/pre_upgrade" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/pre_upgrade" "pacman" "pacman")
    [[ -n "$T" ]] && PRE_UPGRADE+="$T"$'\n'
  fi
  if [[ -f "$INTDIR/meta/scripts/post_upgrade" ]]; then
    T=$(translate_script "$INTDIR/meta/scripts/post_upgrade" "pacman" "pacman")
    [[ -n "$T" ]] && POST_UPGRADE+="$T"$'\n'
  fi
fi

# Detect systemd unit files and add native handling
SYSTEMD_UNITS=$(find "$INTDIR/root" -name '*.service' -o -name '*.timer' -o -name '*.socket' -o -name '*.path' 2>/dev/null | sed 's|.*/||' | sort -u || true)
if [[ -n "$SYSTEMD_UNITS" ]]; then
  for unit in $SYSTEMD_UNITS; do
    POST_INSTALL+="  systemctl daemon-reload"$'\n'
    POST_INSTALL+="  systemctl enable $unit 2>/dev/null || :"$'\n'
    POST_UPGRADE+="  systemctl daemon-reload"$'\n'
    POST_UPGRADE+="  systemctl try-restart $unit 2>/dev/null || :"$'\n'
    PRE_REMOVE+="  systemctl disable --now $unit 2>/dev/null || :"$'\n'
    POST_REMOVE+="  systemctl daemon-reload"$'\n'
  done
fi

# Write .INSTALL
> "$INSTALL_FILE"

write_func() {
  local func_name="$1" body="$2"
  if [[ -n "${body// /}" ]]; then
    HAS_INSTALL=true
    echo "${func_name}() {" >> "$INSTALL_FILE"
    echo "$body" >> "$INSTALL_FILE"
    echo "}" >> "$INSTALL_FILE"
    echo "" >> "$INSTALL_FILE"
  fi
}

write_func "pre_install"   "$PRE_INSTALL"
write_func "post_install"  "$POST_INSTALL"
write_func "pre_upgrade"   "$PRE_UPGRADE"
write_func "post_upgrade"  "$POST_UPGRADE"
write_func "pre_remove"    "$PRE_REMOVE"
write_func "post_remove"   "$POST_REMOVE"

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

# Metapackage: only metadata files. Otherwise: metadata + content.
HAS_CONTENT=false
if [[ -n "$(find . -mindepth 1 -not -name '.PKGINFO' -not -name '.MTREE' -not -name '.INSTALL' -not -name '.BUILDINFO' -print -quit 2>/dev/null)" ]]; then
  HAS_CONTENT=true
fi

if $HAS_CONTENT; then
  if ! tar -I 'zstd -19 -T0' -cf "$OUTDIR/$PKG_FILENAME" \
    $TAR_FILES \
    --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.INSTALL' --exclude='.BUILDINFO' \
    ./* 2>/dev/null; then
    echo "WARNING: tar failed with content, retrying metadata-only" >&2
    tar -I 'zstd -19 -T0' -cf "$OUTDIR/$PKG_FILENAME" $TAR_FILES
  fi
else
  tar -I 'zstd -19 -T0' -cf "$OUTDIR/$PKG_FILENAME" $TAR_FILES
fi

echo "Pacman package built: $OUTDIR/$PKG_FILENAME"
