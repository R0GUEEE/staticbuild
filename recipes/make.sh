#!/bin/sh
# deps: build-base
# GNU make 4.4.1 — Theos makefiles need GNU semantics, not BSD make.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://ftp.gnu.org/gnu/make/make-$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/make"
cd "$SB_WORK/src/make/make-$SB_VERSION"

case "$SB_FAMILY" in
  elf)
    ./configure --disable-nls --without-guile --prefix=/usr \
      CFLAGS="$(sb_cflags)" LDFLAGS="-static -s"
    ;;
  macho)
    ./configure --disable-nls --without-guile --prefix=/usr \
      CFLAGS="$(sb_cflags)" LDFLAGS="$(sb_cflags) -Wl,-dead_strip"
    ;;
esac

make -j "$SB_JOBS"
sb_bin make make
sb_symlinks gmake
SB_PATHS=bin
sb_finish
