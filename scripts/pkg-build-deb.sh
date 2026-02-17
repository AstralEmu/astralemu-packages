#!/bin/bash
# pkg-build-deb.sh — Build a .deb from the intermediate format
# Usage: ./pkg-build-deb.sh <intermediate-dir> <output-dir> [--dep-map <dep-map.conf>] [--target-distro <codename>]
#
# Supports any source format: deb, rpm, pacman → deb
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cross-pkg-helpers.sh
source "$SCRIPT_DIR/cross-pkg-helpers.sh"

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
SOURCE_FORMAT=$(cat "$INTDIR/meta/source_format")
SOURCE_DISTRO=$(cat "$INTDIR/meta/source_distro" 2>/dev/null || echo "unknown")

# Map arch to deb convention
case "$PKG_ARCH" in
  aarch64) DEB_ARCH="arm64" ;;
  x86_64)  DEB_ARCH="amd64" ;;
  armhf)   DEB_ARCH="armhf" ;;
  *)       DEB_ARCH="$PKG_ARCH" ;;
esac

# Map dependency names: source format -> deb names
map_dep_to_deb() {
  local dep="$1"

  if [[ "$SOURCE_FORMAT" == "deb" ]]; then
    echo "$dep"
    return
  fi

  if [[ -n "$DEP_MAP" && -f "$DEP_MAP" ]]; then
    local mapped=""
    if [[ "$SOURCE_FORMAT" == "rpm" ]]; then
      mapped=$(grep "rpm:${dep}" "$DEP_MAP" | head -1 | cut -d'=' -f1 | tr -d ' ' || true)
    elif [[ "$SOURCE_FORMAT" == "pacman" ]]; then
      mapped=$(grep "pac:${dep}" "$DEP_MAP" | head -1 | cut -d'=' -f1 | tr -d ' ' || true)
    fi
    if [[ -n "$mapped" ]]; then
      echo "$mapped"
      return
    fi
  fi

  echo "$dep"
}

# ========================================================================
# Relocate library paths (RPM lib64 → /usr/lib for Debian)
# ========================================================================
if [[ "$SOURCE_FORMAT" != "deb" ]]; then
  relocate_lib_paths "$INTDIR/root" "/usr/lib"
fi

# ========================================================================

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

# ========================================================================
# Conffiles → DEBIAN/conffiles
# ========================================================================
if [[ -s "$INTDIR/meta/conffiles" ]]; then
  # Only include conffiles that actually exist in the package
  while IFS= read -r cf; do
    [[ -z "$cf" ]] && continue
    [[ -e "$BUILDDIR$cf" ]] && echo "$cf"
  done < "$INTDIR/meta/conffiles" > "$BUILDDIR/DEBIAN/conffiles"
  # Remove if empty
  [[ -s "$BUILDDIR/DEBIAN/conffiles" ]] || rm -f "$BUILDDIR/DEBIAN/conffiles"
fi

# ========================================================================
# Translate and install maintainer scripts
# For deb source: copy as-is (same format)
# For rpm/pacman source: translate commands to Debian equivalents
# ========================================================================
if [[ "$SOURCE_FORMAT" == "deb" ]]; then
  # Same format: copy scripts directly
  for script in preinst postinst prerm postrm; do
    if [[ -f "$INTDIR/meta/scripts/$script" ]]; then
      cp "$INTDIR/meta/scripts/$script" "$BUILDDIR/DEBIAN/$script"
      chmod 755 "$BUILDDIR/DEBIAN/$script"
    fi
  done
else
  if [[ "$SOURCE_FORMAT" == "rpm" ]]; then
    # ---- RPM → deb: translate with runtime $_RPM_ARG ----
    # RPM scripts use numeric $1 to distinguish install ($1=1) vs upgrade ($1=2)
    # and uninstall ($1=0) vs before-upgrade ($1=1).
    # Deb scripts receive text arguments ($1=configure/install/upgrade/remove).
    # We replace $1→$_RPM_ARG and prepend a preamble that maps deb args → RPM numeric.
    for script in preinst postinst prerm postrm; do
      if [[ -f "$INTDIR/meta/scripts/$script" ]]; then
        RPM_PREAMBLE=""
        case "$script" in
          preinst)  RPM_PREAMBLE='case "$1" in install) _RPM_ARG=1 ;; upgrade) _RPM_ARG=2 ;; *) _RPM_ARG=1 ;; esac' ;;
          postinst) RPM_PREAMBLE='if [ -z "$2" ]; then _RPM_ARG=1; else _RPM_ARG=2; fi' ;;
          prerm)    RPM_PREAMBLE='case "$1" in remove) _RPM_ARG=0 ;; upgrade) _RPM_ARG=1 ;; *) _RPM_ARG=0 ;; esac' ;;
          postrm)   RPM_PREAMBLE='case "$1" in remove|purge) _RPM_ARG=0 ;; upgrade) _RPM_ARG=1 ;; *) _RPM_ARG=0 ;; esac' ;;
        esac

        TRANSLATED=$(translate_script "$INTDIR/meta/scripts/$script" "rpm" "deb" "runtime")
        if [[ -n "$TRANSLATED" ]]; then
          {
            echo "#!/bin/bash"
            echo "$RPM_PREAMBLE"
            echo "$TRANSLATED"
          } > "$BUILDDIR/DEBIAN/$script"
          chmod 755 "$BUILDDIR/DEBIAN/$script"
        fi
      fi
    done

  elif [[ "$SOURCE_FORMAT" == "pacman" ]]; then
    # ---- Pacman → deb: map install/upgrade/remove functions with guards ----
    # Pacman has separate functions (pre_install vs pre_upgrade vs pre_remove).
    # Deb scripts run on all events, so we add guards to match Pacman semantics:
    #   preinst:  install → pre_install, upgrade → pre_upgrade
    #   postinst: fresh ($2 empty) → post_install, upgrade ($2 set) → post_upgrade
    #   prerm:    remove → pre_remove
    #   postrm:   remove/purge → post_remove
    for script in preinst postinst prerm postrm; do
      BODY=""

      # Install/remove scripts with appropriate guards
      if [[ -f "$INTDIR/meta/scripts/$script" ]]; then
        TRANSLATED=$(translate_script "$INTDIR/meta/scripts/$script" "pacman" "deb")
        if [[ -n "$TRANSLATED" ]]; then
          case "$script" in
            preinst)  BODY+='if [ "$1" = "install" ]; then'$'\n'"$TRANSLATED"$'\n''fi'$'\n' ;;
            postinst) BODY+='if [ -z "$2" ]; then'$'\n'"$TRANSLATED"$'\n''fi'$'\n' ;;
            prerm)    BODY+='if [ "$1" = "remove" ]; then'$'\n'"$TRANSLATED"$'\n''fi'$'\n' ;;
            postrm)   BODY+='if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then'$'\n'"$TRANSLATED"$'\n''fi'$'\n' ;;
          esac
        fi
      fi

      # Merge upgrade scripts with upgrade guards
      case "$script" in
        preinst)
          if [[ -f "$INTDIR/meta/scripts/pre_upgrade" ]]; then
            TRANSLATED=$(translate_script "$INTDIR/meta/scripts/pre_upgrade" "pacman" "deb")
            [[ -n "$TRANSLATED" ]] && BODY+='if [ "$1" = "upgrade" ]; then'$'\n'"$TRANSLATED"$'\n''fi'$'\n'
          fi ;;
        postinst)
          if [[ -f "$INTDIR/meta/scripts/post_upgrade" ]]; then
            TRANSLATED=$(translate_script "$INTDIR/meta/scripts/post_upgrade" "pacman" "deb")
            [[ -n "$TRANSLATED" ]] && BODY+='if [ -n "$2" ]; then'$'\n'"$TRANSLATED"$'\n''fi'$'\n'
          fi ;;
      esac

      if [[ -n "$BODY" ]]; then
        {
          echo "#!/bin/bash"
          echo "$BODY"
        } > "$BUILDDIR/DEBIAN/$script"
        chmod 755 "$BUILDDIR/DEBIAN/$script"
      fi
    done

  else
    # ---- Unknown source → deb: best-effort translation ----
    for script in preinst postinst prerm postrm; do
      if [[ -f "$INTDIR/meta/scripts/$script" ]]; then
        TRANSLATED=$(translate_script "$INTDIR/meta/scripts/$script" "$SOURCE_FORMAT" "deb")
        if [[ -n "$TRANSLATED" ]]; then
          {
            echo "#!/bin/bash"
            echo "$TRANSLATED"
          } > "$BUILDDIR/DEBIAN/$script"
          chmod 755 "$BUILDDIR/DEBIAN/$script"
        fi
      fi
    done
  fi
fi

# Build the .deb (strip epoch from filename — colons are invalid on some filesystems)
DEB_VERSION=$(echo "$PKG_VERSION" | sed 's/^[0-9]*://')
DEB_FILE="${PKG_NAME}_${DEB_VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build --root-owner-group "$BUILDDIR" "$OUTDIR/$DEB_FILE"

echo "DEB built: $OUTDIR/$DEB_FILE"
