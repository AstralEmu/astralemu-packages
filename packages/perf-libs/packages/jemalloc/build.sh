#!/bin/bash
set -e

if [[ ! -d /workspace/src-jemalloc ]]; then
  git clone https://github.com/jemalloc/jemalloc.git /workspace/src-jemalloc
fi

cd /workspace/src-jemalloc
git fetch --tags
LATEST=$(git tag -l '[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -1)
echo "Using jemalloc: $LATEST"
git checkout "$LATEST"

./autogen.sh
./configure --prefix=/usr \
  CFLAGS="$TARGET_CFLAGS -flto=thin" \
  CXXFLAGS="$TARGET_CXXFLAGS -flto=thin" \
  LDFLAGS="$TARGET_LDFLAGS"

make -j"$NPROC"
make DESTDIR="$PREFIX" install
make install
