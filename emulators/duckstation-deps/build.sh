#!/bin/bash
set -e

mkdir -p /deps

case "$DEVICE_ARCH" in
  amd64)
    # Prebuilt x86_64 deps — check if latest upstream release changed
    LATEST_RELEASE=$(git ls-remote --tags --sort=-v:refname https://github.com/duckstation/dependencies.git 'refs/tags/release-*' 2>/dev/null | head -1 | sed 's|.*refs/tags/||')
    CACHED_RELEASE=""
    [[ -f /deps/.release-tag ]] && CACHED_RELEASE=$(cat /deps/.release-tag)

    if [[ -n "$CACHED_RELEASE" && "$CACHED_RELEASE" == "$LATEST_RELEASE" ]] && ls /deps/lib/*.so* 1>/dev/null 2>&1; then
      echo "Dependencies up to date ($CACHED_RELEASE), skipping download"
      echo "completed" > /workspace/build-status
      exit 0
    fi

    echo "Deps update needed: cached=$CACHED_RELEASE latest=$LATEST_RELEASE"
    rm -rf /deps/*
    DEPS_URL="https://github.com/duckstation/dependencies/releases/download/$LATEST_RELEASE/deps-linux-x64.tar.xz"
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
    echo "$LATEST_RELEASE" > /deps/.release-tag
    ;;
  arm64)
    # No native ARM64 prebuilt deps — build from source
    # Check if upstream deps repo changed since last build
    LATEST_COMMIT=$(git ls-remote https://github.com/duckstation/dependencies.git HEAD 2>/dev/null | cut -f1)
    CACHED_COMMIT=""
    [[ -f /deps/.deps-commit ]] && CACHED_COMMIT=$(cat /deps/.deps-commit)

    if [[ -n "$CACHED_COMMIT" && "$CACHED_COMMIT" == "$LATEST_COMMIT" ]] && ls /deps/lib/*.so* 1>/dev/null 2>&1; then
      echo "Dependencies up to date ($CACHED_COMMIT), skipping build"
      echo "completed" > /workspace/build-status
      exit 0
    fi

    echo "Deps update needed: cached=$CACHED_COMMIT latest=$LATEST_COMMIT"
    rm -rf /deps/*
    echo "Building dependencies from source for ARM64..."
    git clone --depth 1 https://github.com/duckstation/dependencies.git /tmp/duck-deps-src
    /tmp/duck-deps-src/build-dependencies-linux.sh /deps
    rm -rf /tmp/duck-deps-src
    echo "$LATEST_COMMIT" > /deps/.deps-commit
    ;;
  *)
    echo "Unsupported architecture: $DEVICE_ARCH"; exit 1
    ;;
esac

echo "Dependencies ready"
echo "completed" > /workspace/build-status
