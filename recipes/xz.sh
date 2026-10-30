#!/bin/sh
# deps: build-base autoconf automake libtool gettext-dev
# XZ Utils — needed by dpkg-deb for -Zxz and by every .tar.xz source tarball.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/tukaani-project/xz/releases/download/v$SB_VERSION/xz-$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/xz"
sb_cd "$SB_WORK/src/xz/xz-$SB_VERSION"

./configure --disable-shared --enable-static --disable-nls --disable-doc \
  --disable-ifunc --prefix=/usr \
  CFLAGS="$(sb_cflags)" LDFLAGS="-static -s"
make -j "$SB_JOBS" LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -all-static) -s"

sb_bin src/xz/xz xz
sb_symlinks unxz xzcat lzma unzlzma
export SB_PATHS=bin
sb_finish
