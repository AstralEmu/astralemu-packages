#!/bin/bash
# pkg-build-rpm.sh — Build an .rpm from the intermediate format
# Usage: ./pkg-build-rpm.sh <intermediate-dir> <output-dir> [--dep-map <dep-map.conf>]
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
  aarch64) RPM_ARCH="aarch64" ;;
  x86_64)  RPM_ARCH="x86_64" ;;
  *)       RPM_ARCH="$PKG_ARCH" ;;
esac

# Clean version for RPM (no colons, translate hyphens)
RPM_VERSION=$(echo "$PKG_VERSION" | tr ':~' '..' | sed 's/-/./g')

# Map dependency name to RPM name
map_dep_to_rpm() {
  local dep="$1"
  local source_format
  source_format=$(cat "$INTDIR/meta/source_format")

  # If already RPM, keep as-is
  if [[ "$source_format" == "rpm" ]]; then
    echo "$dep"
    return
  fi

  if [[ -n "$DEP_MAP" && -f "$DEP_MAP" ]]; then
    local mapped=""
    if [[ "$source_format" == "deb" ]]; then
      # Forward lookup: deb_name = rpm:X
      mapped=$(grep "^${dep} " "$DEP_MAP" | head -1 | grep -oP 'rpm:\K[^,]+' | tr -d ' ')
    elif [[ "$source_format" == "pacman" ]]; then
      # Cross lookup: find the line with pac:X, extract rpm:Y
      mapped=$(grep "pac:${dep}" "$DEP_MAP" | head -1 | grep -oP 'rpm:\K[^,]+' | tr -d ' ')
    fi
    if [[ -n "$mapped" ]]; then
      echo "$mapped"
      return
    fi
  fi

  echo "$dep"
}

# Setup rpmbuild tree
RPMBUILD=$(mktemp -d)
trap 'rm -rf "$RPMBUILD"' EXIT

mkdir -p "$RPMBUILD"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,BUILDROOT}

# Build requires lines
REQUIRES=""
if [[ -s "$INTDIR/meta/depends" ]]; then
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    rpm_dep=$(map_dep_to_rpm "$dep")
    REQUIRES="${REQUIRES}Requires: ${rpm_dep}
"
  done < "$INTDIR/meta/depends"
fi

# Optional provides/conflicts/obsoletes
EXTRA_SPEC=""
if [[ -s "$INTDIR/meta/provides" ]]; then
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    EXTRA_SPEC="${EXTRA_SPEC}Provides: ${p}
"
  done < "$INTDIR/meta/provides"
fi
if [[ -s "$INTDIR/meta/conflicts" ]]; then
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    EXTRA_SPEC="${EXTRA_SPEC}Conflicts: ${c}
"
  done < "$INTDIR/meta/conflicts"
fi
if [[ -s "$INTDIR/meta/replaces" ]]; then
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    EXTRA_SPEC="${EXTRA_SPEC}Obsoletes: ${r}
"
  done < "$INTDIR/meta/replaces"
fi

# Build scriptlet sections
SCRIPTLETS=""
if [[ -f "$INTDIR/meta/scripts/preinst" ]]; then
  SCRIPTLETS="${SCRIPTLETS}
%pre
$(cat "$INTDIR/meta/scripts/preinst")
"
fi
if [[ -f "$INTDIR/meta/scripts/postinst" ]]; then
  SCRIPTLETS="${SCRIPTLETS}
%post
$(cat "$INTDIR/meta/scripts/postinst")
"
fi
if [[ -f "$INTDIR/meta/scripts/prerm" ]]; then
  SCRIPTLETS="${SCRIPTLETS}
%preun
$(cat "$INTDIR/meta/scripts/prerm")
"
fi
if [[ -f "$INTDIR/meta/scripts/postrm" ]]; then
  SCRIPTLETS="${SCRIPTLETS}
%postun
$(cat "$INTDIR/meta/scripts/postrm")
"
fi

# Generate file list
FILE_LIST=$(cd "$INTDIR/root" && find . -type f -o -type l | sed 's|^\.|/|' | sort)

# Create spec file
cat > "$RPMBUILD/SPECS/$PKG_NAME.spec" << SPEC
Name:    $PKG_NAME
Version: $RPM_VERSION
Release: 1
Summary: $PKG_DESC
License: GPL
Packager: $PKG_MAINTAINER
AutoReqProv: no
${REQUIRES}${EXTRA_SPEC}
%description
$PKG_DESC
${SCRIPTLETS}
%install
cp -a $INTDIR/root/* %{buildroot}/

%files
$FILE_LIST
SPEC

# Also list directories
DIR_LIST=$(cd "$INTDIR/root" && find . -type d ! -name '.' | sed 's|^\.|%dir /|' | sort)
if [[ -n "$DIR_LIST" ]]; then
  echo "$DIR_LIST" >> "$RPMBUILD/SPECS/$PKG_NAME.spec"
fi

# Build RPM
rpmbuild --define "_topdir $RPMBUILD" \
         --define "_rpmdir $OUTDIR" \
         --target "$RPM_ARCH" \
         -bb "$RPMBUILD/SPECS/$PKG_NAME.spec" 2>/dev/null

# Move RPM to output dir root (rpmbuild puts it in arch subdir)
find "$OUTDIR" -name '*.rpm' -path "*/$RPM_ARCH/*" -exec mv {} "$OUTDIR/" \; 2>/dev/null
rmdir "$OUTDIR/$RPM_ARCH" 2>/dev/null || true

echo "RPM built: $OUTDIR/${PKG_NAME}-${RPM_VERSION}-1.${RPM_ARCH}.rpm"
