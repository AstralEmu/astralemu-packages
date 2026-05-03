#!/bin/bash
# kernel-tegra-x1 — Linux 4.9 kernel for the Nintendo Switch (T210).
# Mono-job (no aggregator split): the 4.9 build is short enough on a
# native arm64 runner to fit in one job.
set -euo pipefail
. /workspace/scripts/kernel-helpers.sh

# --- Source ---------------------------------------------------------------
SRC=/workspace/src-kernel-tegra
if [[ ! -d "$SRC/.git" ]]; then
  echo "Cloning NaGaa95/switch-l4t-kernel-4.9 ..."
  git clone --depth 1 --branch linux-dev \
    https://github.com/NaGaa95/switch-l4t-kernel-4.9.git "$SRC"
else
  echo "Reusing existing $SRC"
  ( cd "$SRC" && git fetch --depth 1 origin linux-dev && git reset --hard FETCH_HEAD )
fi
cd "$SRC"

# --- Patches pour équipes manquantes (Tegra X1 / L4T 4.9) ---
# Le repo NaGaa95/switch-l4t-kernel-4.9 référence eqos/Kconfig mais le fichier
# n'existe pas. Créer un fichier Kconfig minimal pour éviter l'erreur.
# source "drivers/net/ethernet/nvidia/eqos/Kconfig"
if [[ ! -d "drivers/net/ethernet/nvidia/eqos" ]]; then
  mkdir -p drivers/net/ethernet/nvidia/eqos
  cat > drivers/net/ethernet/nvidia/eqos/Kconfig <<'EQOS_KCONFIG'
config NET_NVIDIA_EQOS
	tristate "NVIDIA EQOS Ethernet support"
	depends on ARCH_TEGRA || COMPILE_TEST
	default y
	---help---
	  Support pour le contrôleur Ethernet EQOS de NVIDIA Tegra.
EQOS_KCONFIG
  echo "Created missing eqos/Kconfig"
fi

# arch/arm64/Kconfig also sources "drivers/firmware/tegra/Kconfig" which
# does not exist in NaGaa95's fork. Create a minimal stub with the symbols
# referenced by the mainline kernel (TEGRA_IVC, TEGRA_BPMP) so the Kconfig
# parser can proceed. The defconfig uses NV_TEGRA_BPMP instead, but the
# source directive just needs a valid file to parse.
if [[ ! -d "drivers/firmware/tegra" ]]; then
  mkdir -p drivers/firmware/tegra
  cat > drivers/firmware/tegra/Kconfig <<'TEGRA_FW_KCONFIG'
config TEGRA_IVC
	bool "Tegra IVC protocol"
	depends on ARCH_TEGRA

config TEGRA_BPMP
	bool "Tegra BPMP driver"
	depends on ARCH_TEGRA
	select TEGRA_IVC
	---help---
	  Tegra Boot and Power Management Processor driver.
TEGRA_FW_KCONFIG
  echo "Created missing firmware/tegra/Kconfig"
fi

KVER=$(make kernelversion)   # e.g. "4.9.337"
echo "Tegra X1 kernel version: $KVER"

# --- Configure ------------------------------------------------------------
# Switchroot ships its defconfig as tegra_linux_defconfig. Some forks rename
# it; pick whichever exists.
DEFCONFIG=""
for c in arch/arm64/configs/tegra_linux_defconfig \
         arch/arm64/configs/tegra_defconfig \
         arch/arm64/configs/defconfig; do
  if [[ -f "$c" ]]; then DEFCONFIG=$(basename "$c"); break; fi
done
[[ -n "$DEFCONFIG" ]] || { echo "ERROR: no defconfig found in arch/arm64/configs/" >&2; exit 1; }
echo "Using defconfig: $DEFCONFIG"
make ARCH=arm64 "$DEFCONFIG"

# Force the must-have knobs for handheld gaming UX. CONFIG_HZ_1000 is the
# only "BORE-style" knob that 4.9 has — preempt is already PREEMPT in this
# config but we re-assert.
cat >> .config <<'KCONFIG'
CONFIG_HZ_1000=y
CONFIG_HZ=1000
CONFIG_PREEMPT=y
KCONFIG
make ARCH=arm64 olddefconfig

# --- Build ----------------------------------------------------------------
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_MAXSIZE=10G
ccache -z

echo "Building Image + dtbs + modules..."
make ARCH=arm64 -j"$(nproc)" Image dtbs modules
ccache -s

# --- Stage package layout -------------------------------------------------
PKG=/tmp/pkg
rm -rf "$PKG"
mkdir -p "$PKG/meta/scripts" "$PKG/root/boot" "$PKG/root/lib"

cp arch/arm64/boot/Image "$PKG/root/boot/vmlinuz-${KVER}-tegra-x1"
cp System.map            "$PKG/root/boot/System.map-${KVER}-tegra-x1"
cp .config               "$PKG/root/boot/config-${KVER}-tegra-x1"

make ARCH=arm64 INSTALL_MOD_PATH="$PKG/root" INSTALL_MOD_STRIP=1 modules_install

# DTBs in their own sub-package, like for the other ARM kernels.
DTB_PKG=/tmp/pkg-dtbs
rm -rf "$DTB_PKG"
mkdir -p "$DTB_PKG/meta" "$DTB_PKG/root/usr/lib/linux-image-${KVER}/dtbs"
find arch/arm64/boot/dts -name '*.dtb' \
  -exec cp --parents {} "$DTB_PKG/root/usr/lib/linux-image-${KVER}/dtbs/" \;

# depmod against the staged tree so postinst's depmod -a is fast.
if command -v depmod >/dev/null; then
  depmod -b "$PKG/root" "$KVER" || true
fi

# --- main package meta ----------------------------------------------------
echo "kernel-tegra-x1" > "$PKG/meta/name"
echo "$(kernel_pkg_version "$KVER")" > "$PKG/meta/version"
echo "${TARGET_ARCH}" > "$PKG/meta/arch"
cat > "$PKG/meta/description" <<DESC
AstralEmu kernel for Nintendo Switch (Tegra X1, kernel ${KVER}).
Based on NaGaa95/switch-l4t-kernel-4.9 — the only actively maintained
4.9 fork (2026-04 erista support). No BORE / CachyOS (kernel 4.9
incompatible). Pair this with the filtered theofficialgman/l4t-debs
userspace mirror (nvidia-l4t-*, switch-*, joycond, xorg-server) for a
complete Switch L4T stack. See docs/tegra-x1-research.md for the
rationale and the deferred plan to revisit a mainline 6.x port.
DESC
echo "games" > "$PKG/meta/section"
echo "optional" > "$PKG/meta/priority"
cat > "$PKG/meta/depends" <<DEPS
kernel-modules-tegra-x1 (= $(kernel_pkg_version "$KVER"))
astralemu-dtbs-tegra-x1 (= $(kernel_pkg_version "$KVER"))
linux-base
DEPS
bash /workspace/scripts/emit-aliases.sh kernel-tegra-x1 "$PKG/meta"
bash /workspace/scripts/emit-aliases.sh kernel         "$PKG/meta"

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
tar cf "/workspace/kernel-tegra-x1_${PKG_VERSION}_${TARGET_ARCH}.pkg.tar" \
  -C "$PKG" meta root

# --- modules sub-package --------------------------------------------------
SUB=/tmp/pkg-modules
rm -rf "$SUB"
mkdir -p "$SUB/meta" "$SUB/root/lib"
cp -a "$PKG/root/lib/modules" "$SUB/root/lib/"
echo "kernel-modules-tegra-x1" > "$SUB/meta/name"
echo "$PKG_VERSION" > "$SUB/meta/version"
echo "${TARGET_ARCH}" > "$SUB/meta/arch"
echo "Modules for kernel-tegra-x1 (kernel ${KVER})" > "$SUB/meta/description"
echo "games" > "$SUB/meta/section"
echo "optional" > "$SUB/meta/priority"
bash /workspace/scripts/emit-aliases.sh kernel-modules-tegra-x1 "$SUB/meta"
bash /workspace/scripts/emit-aliases.sh kernel-modules          "$SUB/meta"
bash /workspace/scripts/finalize-meta.sh "$SUB/meta"
tar cf "/workspace/kernel-modules-tegra-x1_${PKG_VERSION}_${TARGET_ARCH}.pkg.tar" \
  -C "$SUB" meta root

# --- dtbs sub-package -----------------------------------------------------
echo "astralemu-dtbs-tegra-x1" > "$DTB_PKG/meta/name"
echo "$PKG_VERSION" > "$DTB_PKG/meta/version"
echo "all" > "$DTB_PKG/meta/arch"
echo "Device-tree blobs for kernel-tegra-x1 (kernel ${KVER})" \
  > "$DTB_PKG/meta/description"
echo "kernel" > "$DTB_PKG/meta/section"
echo "optional" > "$DTB_PKG/meta/priority"
bash /workspace/scripts/emit-aliases.sh astralemu-dtbs-tegra-x1 "$DTB_PKG/meta"
bash /workspace/scripts/emit-aliases.sh astralemu-dtbs         "$DTB_PKG/meta"
bash /workspace/scripts/finalize-meta.sh "$DTB_PKG/meta"
tar cf "/workspace/astralemu-dtbs-tegra-x1_${PKG_VERSION}_all.pkg.tar" \
  -C "$DTB_PKG" meta root

echo "completed" > /workspace/build-status
ls -lh /workspace/*.pkg.tar
