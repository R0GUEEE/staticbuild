#!/bin/sh
# deps: build-base make pkgconf libplist-dev openssl-dev git
# ldid — the signer every jailbreak-adjacent tool needs. Procursus fork:
# entitlements, DER entitlements and ad-hoc signatures for on-device use.
#
# No CMakeLists here (that was an assumption, and CI proved it wrong): ldid is a
# one-file C++ program built by a plain Makefile that asks pkg-config for
# libplist-2.0 and libcrypto. Static linking therefore means pointing those two
# variables at the .a files rather than the .so ones.
. "$(dirname "$0")/_common.sh"
sb_init

sb_git https://github.com/ProcursusTeam/ldid.git "$SB_VERSION" ldid
sb_cd "$SB_WORK/src/ldid"

_prefix=${OPENSSL_PREFIX:-/usr}
_plist=$(pkg-config --cflags libplist-2.0 2>/dev/null || echo "-I/usr/include")

make -j "$SB_JOBS" \
  CXXFLAGS="$(sb_cflags) $_plist -std=c++17 -DHAVE_OPENSSL" \
  LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static) -s" \
  LIBPLIST_INCLUDES="$_plist" \
  LIBPLIST_LIBS="$_prefix/lib/libplist-2.0.a" \
  LIBCRYPTO_INCLUDES="-I$_prefix/include" \
  LIBCRYPTO_LIBS="$_prefix/lib/libcrypto.a"

[ -x ldid ] || die "ldid binary was not produced"

sb_bin ldid ldid
sb_bin ldid ldid2

export SB_PATHS="bin"
export SB_ENTRY="bin/ldid"
sb_finish
