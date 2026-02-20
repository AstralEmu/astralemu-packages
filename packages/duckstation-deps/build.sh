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

# Build dependencies with official script
echo "Building dependencies with official script..."
# Remove -system-harfbuzz to use bundled version
sed -i "s/-system-harfbuzz//" scripts/deps/build-dependencies-linux.sh
scripts/deps/build-dependencies-linux.sh /deps

echo "Dependencies built successfully"
echo "completed" > /workspace/build-status
