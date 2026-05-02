#!/bin/bash
# setperf — single-build noarch package generator.
#
# Runs ONCE per CI run and emits ONE arch=all .pkg.tar per device by
# iterating devices.yml directly. Each .pkg.tar bundles either the
# device-specific setperf script under packages/setperf/<device>/setperf
# (when present) or a no-op fallback. Bash scripts have no architecture,
# so a single build covers all 26 devices regardless of host arch.
set -euo pipefail

cd /workspace

DEVICES_YML="${ASTRALEMU_DEVICES_YML:-/workspace/devices.yml}"

VERSION="1.0.0+${SHORT:-0000000}"

# No-op fallback emitted for devices without a hand-tuned setperf script.
NOOP_SCRIPT=$(mktemp)
cat > "$NOOP_SCRIPT" <<'NOOP'
#!/bin/bash
# AstralEmu setperf — no-op fallback.
#
# This device does not (yet) have a hand-tuned governor / clock / pinning
# profile. Calling setperf is a no-op until per-device tuning ships under
# packages/setperf/<device-id>/setperf in astralemu-packages.
exit 0
NOOP
chmod +x "$NOOP_SCRIPT"

DEVICE_IDS=$(yq -r '.devices[].id' "$DEVICES_YML")
emitted=0
for DEVICE_ID in $DEVICE_IDS; do
  TARGET_DIR="/workspace/packages/setperf/$DEVICE_ID"
  SCRIPT="$TARGET_DIR/setperf"
  if [[ ! -f "$SCRIPT" ]]; then
    SCRIPT="$NOOP_SCRIPT"
    label="no-op"
  else
    label="hand-tuned"
  fi

  PKG_NAME="setperf-${DEVICE_ID}"
  PKG_DIR="/tmp/${PKG_NAME}_${VERSION}"
  rm -rf "$PKG_DIR"
  mkdir -p "$PKG_DIR/root/usr/bin" "$PKG_DIR/meta"

  cp "$SCRIPT" "$PKG_DIR/root/usr/bin/setperf"
  chmod +x "$PKG_DIR/root/usr/bin/setperf"

  echo "$PKG_NAME"           > "$PKG_DIR/meta/name"
  echo "$VERSION"             > "$PKG_DIR/meta/version"
  echo "all"                  > "$PKG_DIR/meta/arch"
  echo "Performance tuning wrapper for ${DEVICE_ID} (${label})" > "$PKG_DIR/meta/description"
  echo "utils"                > "$PKG_DIR/meta/section"
  echo "optional"             > "$PKG_DIR/meta/priority"
  echo "bash"                 > "$PKG_DIR/meta/depends"

  # The Provides keep clients querying `setperf` (without device suffix)
  # resolving correctly — needed by kernel-astralemu's hard dep.
  echo "setperf" > "$PKG_DIR/meta/provides"
  echo "setperf" > "$PKG_DIR/meta/replaces"

  bash /workspace/scripts/finalize-meta.sh "$PKG_DIR/meta"
  tar cf "/workspace/${PKG_NAME}_${VERSION}_all.pkg.tar" -C "$PKG_DIR" meta root
  emitted=$((emitted + 1))
done

echo "Generated $emitted setperf packages (version $VERSION)"
ls -lh /workspace/setperf-*.pkg.tar 2>/dev/null
echo "completed" > /workspace/build-status
