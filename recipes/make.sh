#!/bin/sh
# shellcheck disable=SC2046 # sb_cmake_args/sb_cflags are flag lists
# deps: build-base
# GNU make 4.4.1 — Theos makefiles need GNU semantics, not BSD make.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://ftp.gnu.org/gnu/make/make-$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/make"
sb_cd "$SB_WORK/src/make/make-$SB_VERSION"

case "$SB_FAMILY" in
  pe)
    # GNU make cross-built for Windows: --host selects the mingw tools, and the
    # absence of a POSIX shell at run time is fine because recipes that use make
    # bring their own shell (busybox or sh.exe).
    ./configure --host="$SB_TRIPLE" --disable-nls --without-guile \
      CFLAGS="-O2" LDFLAGS="-static" > "$SB_WORK/make-configure.log" 2>&1 \
      || { tail -20 "$SB_WORK/make-configure.log" >&2; die "make configure failed"; }
    make -j "$SB_JOBS" > "$SB_WORK/make-build.log" 2>&1 \
      || { tail -20 "$SB_WORK/make-build.log" >&2; die "make build failed"; }
    sb_bin make.exe make.exe
    ;;
  elf)
    sb_configure --disable-nls --without-guile --prefix=/usr \
      CFLAGS="$(sb_cflags)" LDFLAGS="$(sb_ldflags) -s"
    ;;
  macho)
    # GNU make's arscan.c includes <ar.h> when HAVE_AR_H is set, and autoconf
    # finds it on the macOS *host* even though the iPhoneOS SDK does not have
    # it, so the build dies on 'ar.h file not found' after a correct configure.
    # The answer has to be supplied rather than detected.
    # Exported, not prefixed: a VAR=value prefix on a *shell function* call is
    # not exported to the configure child process, which is why the first
    # attempt at this changed nothing.
    export ac_cv_header_ar_h=no
    sb_configure --disable-nls --without-guile --prefix=/usr \
      CFLAGS="$(sb_cflags)" LDFLAGS="$(sb_ldflags) -Wl,-dead_strip"
    ;;
esac

make -j "$SB_JOBS"
sb_bin make make
sb_symlinks gmake
export SB_PATHS=bin
sb_finish
