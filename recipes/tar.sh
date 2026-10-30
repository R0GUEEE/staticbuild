#!/bin/sh
# deps: build-base cmake zlib-dev bzip2-dev xz-dev zstd-dev openssl-dev
# bsdtar (libarchive) — Apple semantics for xattrs and resource forks, no gnulib.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/libarchive/libarchive/releases/download/v$SB_VERSION/libarchive-$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/libarchive"
sb_cd "$SB_WORK/src/libarchive/libarchive-$SB_VERSION"

# shellcheck disable=SC2046 # deliberate word splitting
cmake -B out $(sb_cmake_args) -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DENABLE_TEST=OFF -DENABLE_TAR=ON -DENABLE_CPIO=ON -DENABLE_CAT=OFF \
  -DENABLE_OPENSSL=ON -DENABLE_ZLIB=ON -DENABLE_BZip2=ON -DENABLE_LZMA=ON -DENABLE_ZSTD=ON \
  -DCMAKE_C_FLAGS="$(sb_cflags)" \
  -DCMAKE_EXE_LINKER_FLAGS="$([ "$SB_FAMILY" = elf ] && echo -static)"
cmake --build out -j "$SB_JOBS"

sb_bin out/bsdtar tar
sb_bin out/bsdcpio cpio
sb_symlinks bsdtar
export SB_PATHS=bin
sb_finish
