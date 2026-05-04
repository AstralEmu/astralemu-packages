#!/bin/bash
# kernel-amd64 (aggregator) — pull the kernel-image + kernel-modules-*
# artifacts produced by the sub-jobs, merge them into a single .pkg.tar
# with three packages: kernel-amd64, kernel-modules-amd64,
# astralemu-firmware-amd-handheld.
#
# build-chain.yml has already downloaded the sub-job artifacts into
# /workspace/kernel-deps/ via the kernel-*-<target_id> pattern.
set -euo pipefail
. /workspace/scripts/kernel-helpers.sh

DEPS=/workspace/kernel-deps
[[ -d "$DEPS" ]] || { echo "ERROR: $DEPS missing" >&2; exit 1; }

# Detect kernel version from the image artifact (sub-job wrote KVER).
KVER=$(cat "$DEPS/KVER" 2>/dev/null || true)
if [[ -z "$KVER" ]]; then
  # Fallback: derive from the vmlinuz filename
  KVER=$(basename "$DEPS"/boot/vmlinuz-*-amd64 | sed 's/^vmlinuz-//; s/-amd64$//')
fi
[[ -n "$KVER" ]] || { echo "ERROR: cannot determine KVER" >&2; exit 1; }
echo "Aggregating kernel-amd64 for KVER=$KVER"

# ---- Layout the package root ----------------------------------------------
PKG=/tmp/pkg
rm -rf "$PKG"
mkdir -p "$PKG/meta/scripts" "$PKG/root/boot" "$PKG/root/lib"

# Boot artifacts from kernel-image
cp -a "$DEPS/boot/." "$PKG/root/boot/"

# Modules from BOTH module sub-jobs (-platform and -generic). They share
# the top-level metadata files (modules.order, etc.) but their kernel/
# subtrees are disjoint by design — cp -a is enough since the conflicting
# files are identical.
mkdir -p "$PKG/root/lib/modules/${KVER}"
for src in "$DEPS"/lib/modules/"${KVER}"/* "$DEPS"/lib/modules/"${KVER}"/.[!.]*; do
  [[ -e "$src" ]] || continue
  cp -an "$src" "$PKG/root/lib/modules/${KVER}/" 2>/dev/null || true
done

# Generate modules.dep / modules.alias / etc. from the merged tree so the
# postinst depmod -a is fast.
if command -v depmod >/dev/null; then
  depmod -b "$PKG/root" "$KVER" || true
fi

# ---- meta/ ----------------------------------------------------------------
echo "kernel-amd64" > "$PKG/meta/name"
echo "$(kernel_pkg_version "$KVER")" > "$PKG/meta/version"
echo "${TARGET_ARCH}" > "$PKG/meta/arch"
cat > "$PKG/meta/description" <<DESC
AstralEmu kernel for x86_64 handhelds (kernel ${KVER}).
Based on CachyOS/linux (<X.Y>/cachy branch) with BORE scheduler,
handheld drivers, amd-pstate, fixes and performance tweaks
pre-merged. Targets Steam Deck (Van Gogh/Sephiroth), ROG Ally /
Ally X (Phoenix), Legion Go, MSI Claw, GPD Win, AYANEO,
AYN Loki and similar AMD/Intel handheld devices.
DESC
echo "games" > "$PKG/meta/section"
echo "optional" > "$PKG/meta/priority"
cat > "$PKG/meta/depends" <<DEPS
kernel-modules-amd64 (= $(kernel_pkg_version "$KVER"))
linux-base
DEPS

# Provides aliases for every device on this build_target so apt install
# kernel-steam-deck-lcd resolves to kernel-amd64.
bash /workspace/scripts/emit-aliases.sh kernel-amd64 "$PKG/meta"
# Also publish the canonical 'kernel' alias name for the meta-package convention.
bash /workspace/scripts/emit-aliases.sh kernel "$PKG/meta"

# ---- postinst (generic across deb/rpm/pacman) -----------------------------
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

# ---- finalize centralized fields (source_distro, source_format, maintainer) ----
bash /workspace/scripts/finalize-meta.sh "$PKG/meta"

# ---- Tar the final intermediate package -----------------------------------
PKG_VERSION=$(cat "$PKG/meta/version")
tar cf "/workspace/kernel-amd64_${PKG_VERSION}_${TARGET_ARCH}.pkg.tar" \
  -C "$PKG" meta root

# Also emit kernel-modules-amd64 as a separate sub-package. Same approach
# as perf-libs: a tiny .pkg.tar that ships /lib/modules/ only with its
# own meta/, lets distros mark it as the heavy dependency.
SUB=/tmp/pkg-modules
rm -rf "$SUB"
mkdir -p "$SUB/meta/scripts" "$SUB/root/lib"
cp -a "$PKG/root/lib/modules" "$SUB/root/lib/"
echo "kernel-modules-amd64" > "$SUB/meta/name"
echo "$PKG_VERSION" > "$SUB/meta/version"
echo "${TARGET_ARCH}" > "$SUB/meta/arch"
echo "Modules for kernel-amd64 (kernel ${KVER})" > "$SUB/meta/description"
echo "games" > "$SUB/meta/section"
echo "optional" > "$SUB/meta/priority"
bash /workspace/scripts/emit-aliases.sh kernel-modules-amd64 "$SUB/meta"
bash /workspace/scripts/emit-aliases.sh kernel-modules        "$SUB/meta"
bash /workspace/scripts/finalize-meta.sh "$SUB/meta"
tar cf "/workspace/kernel-modules-amd64_${PKG_VERSION}_${TARGET_ARCH}.pkg.tar" \
  -C "$SUB" meta root

echo "completed" > /workspace/build-status
ls -lh /workspace/*.pkg.tar
