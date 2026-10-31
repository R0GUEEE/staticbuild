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
_ssl=ON; _zstd=ON; _acl=ON
if [ "$SB_OS" = ios ]; then
  # No libcrypto, no libzstd and no libacl in the iPhoneOS SDK. libarchive
  # detects acl.h (it exists) and then needs a library that does not, which
  # cmake reports as 'ACL_LIBRARY ... set to NOTFOUND' after a 47 s configure.
  _ssl=OFF; _zstd=OFF; _acl=OFF
fi

cmake -B out $(sb_cmake_args) -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DENABLE_TEST=OFF -DENABLE_TAR=ON -DENABLE_CPIO=ON -DENABLE_CAT=OFF \
  -DENABLE_ACL=$_acl \
  $([ "$SB_OS" = ios ] && echo "-DHAVE_FUTIMESAT=0") \
  -DENABLE_OPENSSL=$_ssl -DENABLE_ZLIB=ON -DENABLE_BZip2=ON -DENABLE_LZMA=ON -DENABLE_ZSTD=$_zstd \
  -DCMAKE_C_FLAGS="$(sb_cflags)" \
  -DCMAKE_EXE_LINKER_FLAGS="$([ "$SB_FAMILY" = elf ] && echo -static)"
if [ "$SB_OS" = ios ] && [ -f out/config.h ]; then
  # libarchive's cmake checks run against the macOS host as well as the SDK, so
  # HAVE_FUTIMESAT is set even though iPhoneOS does not declare it, and
  # archive_read_disk_posix.c then fails on an implicit declaration.
  sed -i '' 's|#define HAVE_FUTIMESAT 1|/* iOS SDK has no futimesat */|' out/config.h
  # Same class of bug: the probe sees the macOS host and enables the MSVC
  # spelling of fseek, which the SDK does not declare.
  sed -i '' 's|#define HAVE__FSEEKI64 1|/* not a Darwin symbol */|' out/config.h
fi

cmake --build out -j "$SB_JOBS"

sb_bin out/bsdtar tar
sb_bin out/bsdcpio cpio
sb_symlinks bsdtar
export SB_PATHS=bin
sb_finish
