#!/bin/bash
# pkg-extract.sh — Extract any package format to a uniform intermediate structure
# Usage: ./pkg-extract.sh <package-file> <output-dir> [--source-distro <codename>]
#
# Supports: .deb, .rpm, .pkg.tar.zst/.pkg.tar.xz
#
# Output structure:
#   <output-dir>/meta/name, version, arch, description, maintainer, depends,
#                     source_format, source_distro, scripts/{preinst,postinst,prerm,postrm}
#   <output-dir>/root/   (file tree to install)
set -euo pipefail

PKG="$1"
OUTDIR="$2"
SOURCE_DISTRO=""

shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-distro) SOURCE_DISTRO="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PKG" || ! -f "$PKG" ]]; then
  echo "Usage: $0 <package-file> <output-dir> [--source-distro <codename>]" >&2
  exit 1
fi

mkdir -p "$OUTDIR/meta/scripts" "$OUTDIR/root"

# Normalize architecture names
normalize_arch() {
  case "$1" in
    arm64|aarch64)          echo "aarch64" ;;
    amd64|x86_64)           echo "x86_64" ;;
    armhf|armv7hl|armv7h|armv7l) echo "armhf" ;;
    *)                      echo "$1" ;;
  esac
}

# Detect format from extension
detect_format() {
  case "$1" in
    *.deb)                    echo "deb" ;;
    *.rpm)                    echo "rpm" ;;
    *.pkg.tar.zst|*.pkg.tar.xz|*.pkg.tar.gz) echo "pacman" ;;
    *) echo "unknown" ;;
  esac
}

FORMAT=$(detect_format "$PKG")

case "$FORMAT" in
  deb)
    # Extract control info
    TMPCTL=$(mktemp -d)
    dpkg-deb -e "$PKG" "$TMPCTL"
    dpkg-deb -x "$PKG" "$OUTDIR/root"

    grep -m1 '^Package:' "$TMPCTL/control" | cut -d' ' -f2 > "$OUTDIR/meta/name"
    grep -m1 '^Version:' "$TMPCTL/control" | cut -d' ' -f2 > "$OUTDIR/meta/version"
    RAW_ARCH=$(grep -m1 '^Architecture:' "$TMPCTL/control" | cut -d' ' -f2)
    normalize_arch "$RAW_ARCH" > "$OUTDIR/meta/arch"
    grep -m1 '^Description:' "$TMPCTL/control" | sed 's/^Description: //' > "$OUTDIR/meta/description"
    grep -m1 '^Maintainer:' "$TMPCTL/control" | sed 's/^Maintainer: //' > "$OUTDIR/meta/maintainer" 2>/dev/null || echo "Unknown" > "$OUTDIR/meta/maintainer"

    # Extract depends (one per line, strip version constraints)
    if grep -q '^Depends:' "$TMPCTL/control"; then
      grep '^Depends:' "$TMPCTL/control" | sed 's/^Depends: //' | tr ',' '\n' | \
        sed 's/([^)]*)//g; s/|.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | \
        grep -v '^$' > "$OUTDIR/meta/depends"
    else
      touch "$OUTDIR/meta/depends"
    fi

    # Extract conffiles
    if [[ -f "$TMPCTL/conffiles" ]]; then
      grep -v '^$' "$TMPCTL/conffiles" > "$OUTDIR/meta/conffiles" 2>/dev/null || true
    fi

    # Copy maintainer scripts
    for script in preinst postinst prerm postrm; do
      if [[ -f "$TMPCTL/$script" ]]; then
        cp "$TMPCTL/$script" "$OUTDIR/meta/scripts/$script"
      fi
    done

    rm -rf "$TMPCTL"
    echo "deb" > "$OUTDIR/meta/source_format"
    ;;

  rpm)
    # Extract metadata
    rpm -qp --queryformat '%{NAME}' "$PKG" > "$OUTDIR/meta/name"
    rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$PKG" > "$OUTDIR/meta/version"
    RAW_ARCH=$(rpm -qp --queryformat '%{ARCH}' "$PKG")
    normalize_arch "$RAW_ARCH" > "$OUTDIR/meta/arch"
    rpm -qp --queryformat '%{SUMMARY}' "$PKG" > "$OUTDIR/meta/description"
    rpm -qp --queryformat '%{PACKAGER}' "$PKG" > "$OUTDIR/meta/maintainer" 2>/dev/null || echo "Unknown" > "$OUTDIR/meta/maintainer"

    # Extract depends
    rpm -qp --requires "$PKG" | grep -v '^rpmlib(' | grep -v '^/' | \
      sed 's/[[:space:]]*[><=].*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | \
      grep -v '^$' | sort -u > "$OUTDIR/meta/depends" || touch "$OUTDIR/meta/depends"

    # Extract files
    TMPEXT=$(mktemp -d)
    cd "$TMPEXT"
    rpm2cpio "$PKG" | cpio -idm 2>/dev/null
    cp -a "$TMPEXT"/* "$OUTDIR/root/" 2>/dev/null || true
    cd - >/dev/null
    rm -rf "$TMPEXT"

    # Extract config files
    rpm -qp --configfiles "$PKG" 2>/dev/null | \
      grep -v '^(contains no files)$' | grep -v '^$' \
      > "$OUTDIR/meta/conffiles" 2>/dev/null || true

    # Extract scripts
    SCRIPTS_RAW=$(rpm -qp --scripts "$PKG" 2>/dev/null || true)
    if [[ -n "$SCRIPTS_RAW" ]]; then
      echo "$SCRIPTS_RAW" | awk '
        /^preinstall scriptlet/  { out="preinst";  next }
        /^postinstall scriptlet/ { out="postinst"; next }
        /^preuninstall scriptlet/  { out="prerm";  next }
        /^postuninstall scriptlet/ { out="postrm"; next }
        /^[a-z]+ scriptlet/       { out="";        next }
        out != "" { print > "'"$OUTDIR/meta/scripts/"'" out }
      '
    fi

    echo "rpm" > "$OUTDIR/meta/source_format"
    ;;

  pacman)
    # Extract everything
    TMPEXT=$(mktemp -d)
    tar xf "$PKG" -C "$TMPEXT"

    # Parse .PKGINFO
    if [[ -f "$TMPEXT/.PKGINFO" ]]; then
      grep -m1 '^pkgname' "$TMPEXT/.PKGINFO" | cut -d'=' -f2 | tr -d ' ' > "$OUTDIR/meta/name"
      grep -m1 '^pkgver' "$TMPEXT/.PKGINFO" | cut -d'=' -f2 | tr -d ' ' > "$OUTDIR/meta/version"
      RAW_ARCH=$(grep -m1 '^arch' "$TMPEXT/.PKGINFO" | cut -d'=' -f2 | tr -d ' ')
      normalize_arch "$RAW_ARCH" > "$OUTDIR/meta/arch"
      grep -m1 '^pkgdesc' "$TMPEXT/.PKGINFO" | sed 's/^pkgdesc = //' > "$OUTDIR/meta/description"
      grep -m1 '^packager' "$TMPEXT/.PKGINFO" | sed 's/^packager = //' > "$OUTDIR/meta/maintainer" 2>/dev/null || echo "Unknown" > "$OUTDIR/meta/maintainer"

      # Extract depends (one per line)
      grep '^depend = ' "$TMPEXT/.PKGINFO" | sed 's/^depend = //' | \
        sed 's/[><=].*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | \
        grep -v '^$' > "$OUTDIR/meta/depends" || touch "$OUTDIR/meta/depends"

      # Extract backup/conffiles (pacman stores relative paths, add leading /)
      grep '^backup = ' "$TMPEXT/.PKGINFO" | sed 's/^backup = //; s/^/\//' | \
        grep -v '^$' > "$OUTDIR/meta/conffiles" 2>/dev/null || true
    fi

    # Parse .INSTALL for scripts
    if [[ -f "$TMPEXT/.INSTALL" ]]; then
      awk '
        /^pre_install\(\)/  { fn="preinst";       capture=1; next }
        /^post_install\(\)/ { fn="postinst";      capture=1; next }
        /^pre_remove\(\)/   { fn="prerm";         capture=1; next }
        /^post_remove\(\)/  { fn="postrm";        capture=1; next }
        /^pre_upgrade\(\)/  { fn="pre_upgrade";   capture=1; next }
        /^post_upgrade\(\)/ { fn="post_upgrade";  capture=1; next }
        /^\}/ { if (capture) { capture=0; fn="" }; next }
        capture && fn != "" { print >> "'"$OUTDIR/meta/scripts/"'" fn }
      ' "$TMPEXT/.INSTALL"
      # Add shebang to extracted scripts
      for s in "$OUTDIR/meta/scripts"/{preinst,postinst,prerm,postrm,pre_upgrade,post_upgrade}; do
        if [[ -f "$s" ]]; then
          sed -i '1i#!/bin/bash' "$s"
          chmod +x "$s"
        fi
      done
    fi

    # Copy files (exclude metadata)
    for item in "$TMPEXT"/*; do
      base=$(basename "$item")
      case "$base" in
        .PKGINFO|.MTREE|.INSTALL|.BUILDINFO|.CHANGELOG) continue ;;
        *) cp -a "$item" "$OUTDIR/root/" ;;
      esac
    done

    rm -rf "$TMPEXT"
    echo "pacman" > "$OUTDIR/meta/source_format"
    ;;

  *)
    echo "ERROR: Unsupported package format: $PKG" >&2
    exit 1
    ;;
esac

# Write source distro
echo "${SOURCE_DISTRO:-unknown}" > "$OUTDIR/meta/source_distro"

echo "Extracted $(cat "$OUTDIR/meta/name") $(cat "$OUTDIR/meta/version") ($(cat "$OUTDIR/meta/source_format") from ${SOURCE_DISTRO:-unknown})"
