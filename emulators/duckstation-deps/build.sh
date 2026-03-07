#!/bin/bash
set -e

# Skip if deps already cached
if [[ -d /deps/lib ]] && ls /deps/lib/*.so* 1>/dev/null 2>&1; then
  echo "Dependencies already cached, skipping download"
  echo "completed" > /workspace/build-status
  exit 0
fi

mkdir -p /deps

case "$DEVICE_ARCH" in
  amd64)
    # Prebuilt x86_64 deps available upstream
    DEPS_RELEASE="release-20260224"
    DEPS_URL="https://github.com/duckstation/dependencies/releases/download/$DEPS_RELEASE/deps-linux-x64.tar.xz"
    echo "Downloading prebuilt deps: $DEPS_URL"
    curl -L -o /tmp/deps.tar.xz "$DEPS_URL"
    tar xf /tmp/deps.tar.xz -C /deps
    SUBDIRS=(/deps/*/)
    if [[ ${#SUBDIRS[@]} -eq 1 ]] && [[ -d "${SUBDIRS[0]}lib" ]]; then
      mv "${SUBDIRS[0]}"* /deps/ 2>/dev/null || true
      mv "${SUBDIRS[0]}".* /deps/ 2>/dev/null || true
      rmdir "${SUBDIRS[0]}" 2>/dev/null || true
    fi
    rm /tmp/deps.tar.xz
    ;;
  arm64)
    # No native ARM64 prebuilt deps — build from source using the official
    # script from duckstation/dependencies (same as switch-linux-builder did).
    echo "Building dependencies from source for ARM64..."
    git clone --depth 1 https://github.com/duckstation/dependencies.git /tmp/duck-deps-src
    /tmp/duck-deps-src/build-dependencies-linux.sh /deps
    rm -rf /tmp/duck-deps-src
    ;;
  *)
    echo "Unsupported architecture: $DEVICE_ARCH"; exit 1
    ;;
esac

echo "Dependencies ready"
echo "completed" > /workspace/build-status
