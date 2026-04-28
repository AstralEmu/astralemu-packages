#!/bin/bash
# kernel-arm64-legacy (aggregator) — merge sub-job artifacts into the
# final .pkg.tar (kernel + modules sub-package + dtbs sub-package).
set -euo pipefail
. /workspace/scripts/kernel-helpers.sh

DEPS=/workspace/kernel-deps
[[ -d "$DEPS" ]] || { echo "ERROR: $DEPS missing" >&2; exit 1; }

KVER=$(cat "$DEPS/KVER" 2>/dev/null || true)
if [[ -z "$KVER" ]]; then
  KVER=$(basename "$DEPS"/boot/vmlinuz-*-arm64-legacy | sed 's/^vmlinuz-//; s/-arm64-legacy$//')
fi
[[ -n "$KVER" ]] || { echo "ERROR: cannot determine KVER" >&2; exit 1; }
echo "Aggregating kernel-arm64-legacy for KVER=$KVER"

PKG=/tmp/pkg
rm -rf "$PKG"
mkdir -p "$PKG/meta/scripts" "$PKG/root/boot" "$PKG/root/lib"

# Boot artifacts
cp -a "$DEPS/boot/." "$PKG/root/boot/"

# Modules: merge from -soc and -generic (cp -an is fine — disjoint subtrees)
mkdir -p "$PKG/root/lib/modules/${KVER}"
for src in "$DEPS"/lib/modules/"${KVER}"/* "$DEPS"/lib/modules/"${KVER}"/.[!.]*; do
  [[ -e "$src" ]] || continue
  cp -an "$src" "$PKG/root/lib/modules/${KVER}/" 2>/dev/null || true
done

if command -v depmod >/dev/null; then
  depmod -b "$PKG/root" "$KVER" || true
fi

# DTBs go in their own sub-package — stage them separately.
DTB_PKG=/tmp/pkg-dtbs
rm -rf "$DTB_PKG"
mkdir -p "$DTB_PKG/meta" "$DTB_PKG/root/usr/lib/linux-image-${KVER}"
if [[ -d "$DEPS/dtbs" ]]; then
  cp -a "$DEPS/dtbs/." "$DTB_PKG/root/usr/lib/linux-image-${KVER}/dtbs/"
fi

# ----------- main kernel package meta --------------------------------------
echo "kernel-arm64-legacy-${TARGET_ID}" > "$PKG/meta/name"
echo "$(kernel_pkg_version "$KVER")" > "$PKG/meta/version"
echo "${TARGET_ARCH}" > "$PKG/meta/arch"
cat > "$PKG/meta/description" <<DESC
AstralEmu kernel for armv8-a Cortex-A53/A55/A57/A72/A73 handhelds
(${TARGET_ID} build, kernel ${KVER}). Based on linux-stable + BORE
scheduler + CachyOS portable patches + ROCKNIX SoC downstream patches
for H700, RK3326, RK3399, RK3566, S922X (Mali-Bifrost / Midgard /
Panfrost). Targets Anbernic RG35XX series (H700), RG ARC (S922X),
Odroid Go Super (S922X), Powkiddy V90/X55 (RK3566), original
Anbernic RG35XX (RK3326), Pinebook (RK3399).
Note: Nintendo Switch (Tegra X1) is not covered here — see
kernel-tegra-x1 (separate target on kernel 4.9 via NaGaa95).
DESC
echo "games" > "$PKG/meta/section"
echo "optional" > "$PKG/meta/priority"
cat > "$PKG/meta/depends" <<DEPS
kernel-modules-arm64-legacy-${TARGET_ID} (= $(kernel_pkg_version "$KVER"))
astralemu-dtbs-arm64-legacy-${TARGET_ID} (= $(kernel_pkg_version "$KVER"))
linux-base
DEPS
# l4t (Switch) gets kernel-tegra-x1 instead — drop it from the canonical
# 'kernel'/'kernel-modules'/'astralemu-dtbs' aliases to avoid colliding
# with kernel-tegra-x1's Provides on the Switch's device repo.
NO_L4T=""
IFS=',' read -ra _devs <<< "${TARGET_DEVICES:-}"
for d in "${_devs[@]}"; do
  [[ -z "$d" || "$d" == "l4t" ]] && continue
  NO_L4T+="${NO_L4T:+,}$d"
done

bash /workspace/scripts/emit-aliases.sh kernel-arm64-legacy "$PKG/meta"
TARGET_DEVICES="$NO_L4T" \
  bash /workspace/scripts/emit-aliases.sh kernel "$PKG/meta"

cat > "$PKG/meta/scripts/postinst" <<'POST'
#!/bin/bash
set -e
KVER=$(ls /lib/modules 2>/dev/null | sort -V | tail -n1)
[[ -n "$KVER" ]] || exit 0
depmod -a "$KVER" || true
if   command -v update-initramfs >/dev/null 2>&1; then
  update-initramfs -c -k "$KVER" || update-initramfs -u -k "$KVER" || true
elif command -v dracut >/dev/null 2>&1; then
  dracut --force --kver "$KVER" || true
elif command -v mkinitcpio >/dev/null 2>&1; then
  mkinitcpio -k "$KVER" -g "/boot/initramfs-${KVER}.img" || true
fi
POST
chmod +x "$PKG/meta/scripts/postinst"
bash /workspace/scripts/finalize-meta.sh "$PKG/meta"

PKG_VERSION=$(cat "$PKG/meta/version")
tar cf "/workspace/kernel-arm64-legacy-${TARGET_ID}_${PKG_VERSION}_${TARGET_ARCH}.pkg.tar" \
  -C "$PKG" meta root

# ----------- kernel-modules sub-package -----------------------------------
SUB=/tmp/pkg-modules
rm -rf "$SUB"
mkdir -p "$SUB/meta" "$SUB/root/lib"
cp -a "$PKG/root/lib/modules" "$SUB/root/lib/"
echo "kernel-modules-arm64-legacy-${TARGET_ID}" > "$SUB/meta/name"
echo "$PKG_VERSION" > "$SUB/meta/version"
echo "${TARGET_ARCH}" > "$SUB/meta/arch"
echo "Modules for kernel-arm64-legacy-${TARGET_ID} (kernel ${KVER})" \
  > "$SUB/meta/description"
echo "games" > "$SUB/meta/section"
echo "optional" > "$SUB/meta/priority"
bash /workspace/scripts/emit-aliases.sh kernel-modules-arm64-legacy "$SUB/meta"
TARGET_DEVICES="$NO_L4T" \
  bash /workspace/scripts/emit-aliases.sh kernel-modules "$SUB/meta"
bash /workspace/scripts/finalize-meta.sh "$SUB/meta"
tar cf "/workspace/kernel-modules-arm64-legacy-${TARGET_ID}_${PKG_VERSION}_${TARGET_ARCH}.pkg.tar" \
  -C "$SUB" meta root

# ----------- dtbs sub-package ---------------------------------------------
echo "astralemu-dtbs-arm64-legacy-${TARGET_ID}" > "$DTB_PKG/meta/name"
echo "$PKG_VERSION" > "$DTB_PKG/meta/version"
echo "all" > "$DTB_PKG/meta/arch"
echo "Device-tree blobs for kernel-arm64-legacy-${TARGET_ID} (kernel ${KVER})" \
  > "$DTB_PKG/meta/description"
echo "kernel" > "$DTB_PKG/meta/section"
echo "optional" > "$DTB_PKG/meta/priority"
bash /workspace/scripts/emit-aliases.sh astralemu-dtbs-arm64-legacy "$DTB_PKG/meta"
TARGET_DEVICES="$NO_L4T" \
  bash /workspace/scripts/emit-aliases.sh astralemu-dtbs "$DTB_PKG/meta"
bash /workspace/scripts/finalize-meta.sh "$DTB_PKG/meta"
tar cf "/workspace/astralemu-dtbs-arm64-legacy-${TARGET_ID}_${PKG_VERSION}_all.pkg.tar" \
  -C "$DTB_PKG" meta root

echo "completed" > /workspace/build-status
ls -lh /workspace/*.pkg.tar
