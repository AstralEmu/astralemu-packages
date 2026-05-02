#!/bin/bash
# astralemu-deps-repo — repo configuration meta-package.
#
# Drops apt/dnf/pacman config files pointing to the AstralEmu shared deps
# repository for the current source_distro. Installed automatically by
# kernel-astralemu-<device> (or directly by the user) so that downstream
# package installs can resolve the rebuilt -prefixed dependencies that
# live under {format}/deps/<source_distro>/.
#
# Built once per build_target (TARGET_ID = build_target.id), arch=all,
# but the same .pkg.tar is published into every device repo sharing the
# build_target. The content depends only on SOURCE_DISTRO; we don't
# actually vary anything by build_target, but we go through the same
# matrix entry for consistency with the rest of the pipeline.
set -euo pipefail

cd /workspace

BASE_URL="https://astralemu.github.io/astralemu-packages"

PKG_NAME="astralemu-deps-repo"
HASH_TAG="${SHORT:-${COMMIT:0:7}}"
HASH_TAG="${HASH_TAG:-0000000}"
VERSION="1.0.0+${HASH_TAG}"

PKG=/tmp/pkg-deps-repo
rm -rf "$PKG"
mkdir -p "$PKG/meta/scripts"
mkdir -p "$PKG/root/etc/apt/sources.list.d"
mkdir -p "$PKG/root/etc/yum.repos.d"
mkdir -p "$PKG/root/etc/pacman.d"

# --- APT source (deb822 format) -------------------------------------------
# One file per source_distro (ubuntu-lts, debian-stable, ...). The Suite
# name matches the distros.yml id, which is also used as the dists/<id>/
# directory name on gh-pages — so the client and server agree on a stable
# rolling alias rather than a codename that bumps with each LTS.
cat > "$PKG/root/etc/apt/sources.list.d/astralemu-deps-${SOURCE_DISTRO}.sources" <<EOF
Types: deb
URIs: ${BASE_URL}/apt/deps/${SOURCE_DISTRO}
Suites: ${SOURCE_DISTRO}
Components: main
Signed-By: /usr/share/keyrings/astralemu.gpg
Enabled: yes
EOF

# --- DNF repo --------------------------------------------------------------
cat > "$PKG/root/etc/yum.repos.d/astralemu-deps-${SOURCE_DISTRO}.repo" <<EOF
[astralemu-deps-${SOURCE_DISTRO}]
name=AstralEmu Shared Dependencies (${SOURCE_DISTRO})
baseurl=${BASE_URL}/dnf/deps/${SOURCE_DISTRO}/\$releasever/\$basearch/
enabled=1
gpgcheck=1
gpgkey=${BASE_URL}/dnf/deps/${SOURCE_DISTRO}/astralemu.gpg
EOF

# --- Pacman config snippet ------------------------------------------------
cat > "$PKG/root/etc/pacman.d/astralemu-deps-${SOURCE_DISTRO}" <<EOF
[astralemu-deps-${SOURCE_DISTRO}]
SigLevel = Optional TrustAll
Server = ${BASE_URL}/pacman/deps/${SOURCE_DISTRO}/\$arch
EOF

# --- Postinst (universal — detects package manager) -----------------------
cat > "$PKG/meta/scripts/postinst" <<'POSTINST'
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
chmod +x "$PKG/meta/scripts/postinst"

# --- Prerm (cleanup on uninstall) -----------------------------------------
cat > "$PKG/meta/scripts/prerm" <<'PRERM'
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
chmod +x "$PKG/meta/scripts/prerm"

# --- conffiles (so package managers don't overwrite user edits) -----------
cat > "$PKG/meta/conffiles" <<CONF
/etc/apt/sources.list.d/astralemu-deps-${SOURCE_DISTRO}.sources
/etc/yum.repos.d/astralemu-deps-${SOURCE_DISTRO}.repo
/etc/pacman.d/astralemu-deps-${SOURCE_DISTRO}
CONF

# --- Metadata --------------------------------------------------------------
echo "$PKG_NAME" > "$PKG/meta/name"
echo "$VERSION"  > "$PKG/meta/version"
echo "all"       > "$PKG/meta/arch"
echo "AstralEmu shared dependency repository configuration (${SOURCE_DISTRO})" \
                 > "$PKG/meta/description"
echo "admin"     > "$PKG/meta/section"
echo "optional"  > "$PKG/meta/priority"
echo "curl"      > "$PKG/meta/depends"

bash /workspace/scripts/emit-aliases.sh astralemu-deps-repo "$PKG/meta"
bash /workspace/scripts/finalize-meta.sh "$PKG/meta"

tar cf "/workspace/${PKG_NAME}_${VERSION}_all.pkg.tar" -C "$PKG" meta root

echo "Built ${PKG_NAME} version ${VERSION} (source_distro=${SOURCE_DISTRO})"
echo "completed" > /workspace/build-status
