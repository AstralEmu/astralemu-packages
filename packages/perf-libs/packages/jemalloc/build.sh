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

autoconf
./configure --prefix=/usr \
  CFLAGS="$DEVICE_CFLAGS -flto=thin" \
  CXXFLAGS="$DEVICE_CXXFLAGS -flto=thin"

make -j"$NPROC"
make DESTDIR="$PREFIX" install
make install
