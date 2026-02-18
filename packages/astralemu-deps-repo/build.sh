#!/bin/bash
# Build script for astralemu-deps-repo package (intermediate format)
# Generates repo config files for all package managers pointing to the shared deps repo.
# Usage: ./build.sh <device_id> <arch> <source_distro>
set -e

DEVICE_ID="${1:?Usage: build.sh <device_id> <arch> <source_distro>}"
ARCH="${2:?Usage: build.sh <device_id> <arch> <source_distro>}"
SOURCE_DISTRO="${3:?Usage: build.sh <device_id> <arch> <source_distro>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_URL="https://astralemu.github.io/astralemu-packages"

VERSION="1.0.0"
PKG_NAME="astralemu-deps-repo"
PKG_DIR="/tmp/${PKG_NAME}_${VERSION}_${ARCH}"

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/root/etc/apt/sources.list.d"
mkdir -p "$PKG_DIR/root/etc/yum.repos.d"
mkdir -p "$PKG_DIR/root/etc/pacman.d"
mkdir -p "$PKG_DIR/meta/scripts"

# --- APT source (deb822 format) ---
cat > "$PKG_DIR/root/etc/apt/sources.list.d/astralemu-deps-${SOURCE_DISTRO}.sources" << EOF
Types: deb
URIs: ${BASE_URL}/apt/deps/${SOURCE_DISTRO}
Suites: noble trixie
Components: main
Signed-By: /usr/share/keyrings/astralemu.gpg
Enabled: yes
EOF

# --- DNF repo ---
cat > "$PKG_DIR/root/etc/yum.repos.d/astralemu-deps-${SOURCE_DISTRO}.repo" << EOF
[astralemu-deps-${SOURCE_DISTRO}]
name=AstralEmu Shared Dependencies (${SOURCE_DISTRO})
baseurl=${BASE_URL}/dnf/deps/${SOURCE_DISTRO}/\$releasever/\$basearch/
enabled=1
gpgcheck=1
gpgkey=${BASE_URL}/dnf/deps/${SOURCE_DISTRO}/astralemu.gpg
EOF

# --- Pacman config snippet ---
cat > "$PKG_DIR/root/etc/pacman.d/astralemu-deps-${SOURCE_DISTRO}" << EOF
[astralemu-deps-${SOURCE_DISTRO}]
SigLevel = Optional TrustAll
Server = ${BASE_URL}/pacman/deps/${SOURCE_DISTRO}/\$arch
EOF

# --- Postinst (universal — detects package manager) ---
cat > "$PKG_DIR/meta/scripts/postinst" << 'POSTINST'
#!/bin/bash
set -e
GPG_URL="https://astralemu.github.io/astralemu-packages/apt/deps/astralemu.gpg"
KEYRING="/usr/share/keyrings/astralemu.gpg"

if command -v apt-get >/dev/null 2>&1; then
  mkdir -p "$(dirname "$KEYRING")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$GPG_URL" -o "$KEYRING" 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$KEYRING" "$GPG_URL" 2>/dev/null || true
  fi
  for src in /etc/apt/sources.list.d/astralemu-deps-*.sources; do
    [ -f "$src" ] || continue
    apt-get update -o Dir::Etc::sourcelist="$src" \
      -o Dir::Etc::sourceparts="-" \
      -o APT::Get::List-Cleanup="0" 2>/dev/null || true
  done

elif command -v pacman >/dev/null 2>&1; then
  for snippet in /etc/pacman.d/astralemu-deps-*; do
    [ -f "$snippet" ] || continue
    section=$(basename "$snippet")
    if ! grep -q "Include = /etc/pacman.d/${section}" /etc/pacman.conf 2>/dev/null; then
      if grep -q '^\[core\]' /etc/pacman.conf 2>/dev/null; then
        sed -i "/^\[core\]/i \\[${section}\\]\nInclude = /etc/pacman.d/${section}\n" /etc/pacman.conf
      else
        printf '\n[%s]\nInclude = /etc/pacman.d/%s\n' "$section" "$section" >> /etc/pacman.conf
      fi
    fi
  done
  pacman -Sy 2>/dev/null || true

elif command -v dnf >/dev/null 2>&1; then
  for repo in /etc/yum.repos.d/astralemu-deps-*.repo; do
    [ -f "$repo" ] || continue
    repo_id=$(grep -m1 '^\[' "$repo" | tr -d '[]')
    dnf makecache --repo="$repo_id" 2>/dev/null || true
  done
fi
POSTINST

# --- Prerm (cleanup on uninstall) ---
cat > "$PKG_DIR/meta/scripts/prerm" << 'PRERM'
#!/bin/bash
set -e
if command -v pacman >/dev/null 2>&1; then
  for snippet in /etc/pacman.d/astralemu-deps-*; do
    [ -f "$snippet" ] || continue
    section=$(basename "$snippet")
    sed -i "/^\[${section}\]/{N;/Include = \/etc\/pacman.d\/${section}/d;}" /etc/pacman.conf 2>/dev/null || true
  done
fi
[ -f /usr/share/keyrings/astralemu.gpg ] && rm -f /usr/share/keyrings/astralemu.gpg
PRERM

# --- Metadata ---
echo "$PKG_NAME" > "$PKG_DIR/meta/name"
echo "$VERSION" > "$PKG_DIR/meta/version"
echo "$ARCH" > "$PKG_DIR/meta/arch"
echo "AstralEmu shared dependency repository configuration" > "$PKG_DIR/meta/description"
echo "AstralEmu <noreply@astralemu.github.io>" > "$PKG_DIR/meta/maintainer"
echo "deb" > "$PKG_DIR/meta/source_format"
echo "${SOURCE_DISTRO}" > "$PKG_DIR/meta/source_distro"
echo "admin" > "$PKG_DIR/meta/section"
echo "optional" > "$PKG_DIR/meta/priority"
echo "curl" > "$PKG_DIR/meta/depends"

cat > "$PKG_DIR/meta/conffiles" << CONF
/etc/apt/sources.list.d/astralemu-deps-${SOURCE_DISTRO}.sources
/etc/yum.repos.d/astralemu-deps-${SOURCE_DISTRO}.repo
/etc/pacman.d/astralemu-deps-${SOURCE_DISTRO}
CONF

tar cf "$SCRIPT_DIR/${PKG_NAME}_${VERSION}_${ARCH}.pkg.tar" -C "$PKG_DIR" meta root
echo "Package built: ${PKG_NAME}_${VERSION}_${ARCH}.pkg.tar"
