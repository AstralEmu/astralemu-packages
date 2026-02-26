#!/bin/bash
set -e

# Skip if deps already cached
if [[ -d /deps/lib ]] && ls /deps/lib/*.so* 1>/dev/null 2>&1; then
  echo "Dependencies already cached, skipping download"
  echo "completed" > /workspace/build-status
  exit 0
fi

# Upstream removed build-dependencies-linux.sh (commit cdf6d5bd, Feb 21 2026)
# and switched to prebuilt dependency tarballs hosted on GitHub releases.
DEPS_RELEASE="release-20260224"
case "$DEVICE_ARCH" in
  amd64) DEPS_TARBALL="deps-linux-x64.tar.xz" ;;
  arm64) DEPS_TARBALL="deps-linux-arm64.tar.xz" ;;
  *)     echo "Unsupported architecture: $DEVICE_ARCH"; exit 1 ;;
esac

DEPS_URL="https://github.com/duckstation/dependencies/releases/download/$DEPS_RELEASE/$DEPS_TARBALL"
echo "Downloading prebuilt deps: $DEPS_URL"
curl -L -o /tmp/deps.tar.xz "$DEPS_URL"

# Extract to /deps
mkdir -p /deps
tar xf /tmp/deps.tar.xz -C /deps
# If tarball has a single top-level directory, flatten it
SUBDIRS=(/deps/*/)
if [[ ${#SUBDIRS[@]} -eq 1 ]] && [[ -d "${SUBDIRS[0]}lib" ]]; then
  mv "${SUBDIRS[0]}"* /deps/ 2>/dev/null || true
  mv "${SUBDIRS[0]}".* /deps/ 2>/dev/null || true
  rmdir "${SUBDIRS[0]}" 2>/dev/null || true
fi
rm /tmp/deps.tar.xz

echo "Dependencies downloaded successfully"
echo "completed" > /workspace/build-status
