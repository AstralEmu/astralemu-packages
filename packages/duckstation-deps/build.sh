#!/bin/bash
set -e

# Skip if deps already built (cache hit)
if [[ -d /deps/lib ]] && ls /deps/lib/*.so* 1>/dev/null 2>&1; then
  echo "Dependencies already cached, skipping build"
  echo "completed" > /workspace/build-status
  exit 0
fi

# Clone source
git clone --depth 1 https://github.com/stenzek/duckstation.git /workspace/src-duck
cd /workspace/src-duck
git fetch --depth 1 origin "$COMMIT"
git checkout "$COMMIT"

# Build zstd >= 1.5.7 (duckstation requires it, Ubuntu 24.04 ships 1.5.5)
echo "Building zstd from source..."
git clone --depth 1 --branch v1.5.7 https://github.com/facebook/zstd.git /tmp/zstd-src
make -C /tmp/zstd-src lib -j"$(nproc)"
make -C /tmp/zstd-src install PREFIX=/usr/local
mkdir -p /deps
make -C /tmp/zstd-src install PREFIX=/deps
ldconfig
rm -rf /tmp/zstd-src

# Build dependencies with official script
echo "Building dependencies with official script..."
# Remove -system-harfbuzz to use bundled version
sed -i "s/-system-harfbuzz//" scripts/deps/build-dependencies-linux.sh
# Remove checksum verification (GitHub regenerates commit tarballs, changing hashes)
sed -i '/shasum.*--check/d' scripts/deps/build-dependencies-linux.sh
scripts/deps/build-dependencies-linux.sh /deps

echo "Dependencies built successfully"
echo "completed" > /workspace/build-status
