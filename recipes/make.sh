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
    # The iPhoneOS SDK has no <ar.h>, and make's arscan.c includes it
    # unconditionally on every non-Windows, non-Android platform (the guarded
    # fallback struct exists only for BEOS/ZOS). No configure answer can help:
    # the header has to exist. This is binutils' own definition, which is also
    # the layout Mach-O static archives use, so symbol table scanning stays
    # correct rather than being stubbed out.
    mkdir -p "$SB_WORK/compat"
    cat > "$SB_WORK/compat/ar.h" <<'ARH'
#ifndef SB_COMPAT_AR_H
#define SB_COMPAT_AR_H
/* Supplied for platforms whose SDK omits <ar.h> (iPhoneOS). Layout per
   binutils/include/aout/ar.h; ARMAG/ARFMAG are the same on Mach-O archives. */
#define ARMAG  "!<arch>\n"
#define SARMAG 8
#define ARFMAG "`\n"
struct ar_hdr {
  char ar_name[16];
  char ar_date[12];
  char ar_uid[6];
  char ar_gid[6];
  char ar_mode[8];
  char ar_size[10];
  char ar_fmag[2];
};
#endif
ARH
    sb_configure --disable-nls --without-guile --prefix=/usr \
      CPPFLAGS="-I$SB_WORK/compat" \
      CFLAGS="$(sb_cflags)" LDFLAGS="$(sb_ldflags) -Wl,-dead_strip"
    ;;
esac

make -j "$SB_JOBS"
sb_bin make make
sb_symlinks gmake
export SB_PATHS=bin
sb_finish
