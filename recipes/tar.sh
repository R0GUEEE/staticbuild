#!/bin/sh
# shellcheck disable=SC2046 # sb_cmake_args/sb_cflags are flag lists
# deps: build-base cmake zlib-dev bzip2-dev xz-dev zstd-dev openssl-dev
# bsdtar (libarchive) — Apple semantics for xattrs and resource forks, no gnulib.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/libarchive/libarchive/releases/download/v$SB_VERSION/libarchive-$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/libarchive"
sb_cd "$SB_WORK/src/libarchive/libarchive-$SB_VERSION"

# libarchive's optional codecs are a host-package question on Linux and an SDK
# question on iOS: the iPhoneOS SDK ships libz, libbz2 and liblzma stubs but no
# libcrypto and no libzstd, so asking for them makes cmake fail with a NOTFOUND
# variable rather than a missing-header error. Only enable what the SDK has.
_ssl=ON; _zstd=ON
if [ "$SB_OS" = ios ]; then _ssl=OFF; _zstd=OFF; fi

cmake -B out $(sb_cmake_args) -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DENABLE_TEST=OFF -DENABLE_TAR=ON -DENABLE_CPIO=ON -DENABLE_CAT=OFF \
  -DENABLE_OPENSSL=$_ssl -DENABLE_ZLIB=ON -DENABLE_BZip2=ON -DENABLE_LZMA=ON -DENABLE_ZSTD=$_zstd \
  -DCMAKE_C_FLAGS="$(sb_cflags)" \
  -DCMAKE_EXE_LINKER_FLAGS="$([ "$SB_FAMILY" = elf ] && echo -static)"
cmake --build out -j "$SB_JOBS"

sb_bin out/bsdtar tar
sb_bin out/bsdcpio cpio
sb_symlinks bsdtar
export SB_PATHS=bin
sb_finish
