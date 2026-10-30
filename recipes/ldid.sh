#!/bin/sh
# shellcheck disable=SC2046 # sb_cmake_args/sb_cflags are flag lists
# deps: build-base make pkgconf libxml2-dev git autoconf automake libtool
# ldid — the signer every jailbreak-adjacent tool needs. Procursus fork:
# entitlements, DER entitlements and ad-hoc signatures for on-device use.
#
# Order matters here, and getting it wrong cost four CI round-trips:
#   1. libplist, statically (upstream is autotools-first, not CMake, and distro
#      libplist-dev ships no .a);
#   2. OpenSSL, statically (Alpine's openssl-dev ships no libcrypto.a either);
#   3. only then clone ldid and run its Makefile, because each step above ends
#      with a `cd` somewhere else.
. "$(dirname "$0")/_common.sh"
sb_init

LIBPLIST_VERSION=${LIBPLIST_VERSION:-2.6.0}
OPENSSL_VERSION=${OPENSSL_VERSION:-3.4.0}
_plist="$SB_WORK/libplist"
_ssl=${OPENSSL_PREFIX:-$SB_WORK/openssl}

# --- 1. libplist ------------------------------------------------------------
if [ ! -f "$_plist/lib/libplist-2.0.a" ]; then
  src=$(sb_fetch "https://github.com/libimobiledevice/libplist/releases/download/$LIBPLIST_VERSION/libplist-$LIBPLIST_VERSION.tar.bz2")
  sb_unpack "$src" "$SB_WORK/src/libplist"
  _root=$(find "$SB_WORK/src/libplist" -maxdepth 2 -type d -name "libplist-*" | head -1)
  [ -n "$_root" ] || die "libplist: tarball has no libplist-* directory"
  sb_cd "$_root"

  if [ -f configure ]; then
    sb_configure --prefix="$_plist" --enable-static --disable-shared \
      --without-cython CFLAGS="$(sb_cflags)" LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static)"
  else
    ./autogen.sh --prefix="$_plist" --enable-static --disable-shared \
      --without-cython CFLAGS="$(sb_cflags)" LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static)"
  fi
  make -j "$SB_JOBS"
  make install
  [ -f "$_plist/lib/libplist-2.0.a" ] || die "libplist: static archive was not installed"
fi

# --- 2. OpenSSL (static, libs only) -----------------------------------------
if [ ! -f "$_ssl/lib/libcrypto.a" ]; then
  _ossl=$(sb_fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz")
  sb_unpack "$_ossl" "$SB_WORK/src/openssl-ldid"
  sb_cd "$SB_WORK/src/openssl-ldid/openssl-$OPENSSL_VERSION"

  case "$SB_TARGET" in
    linux-arm64)  _bt=linux-aarch64 ;;
    linux-x86_64) _bt=linux-x86_64 ;;
    macos-arm64)  _bt=darwin64-arm64-cc ;;
    *)            _bt=linux-aarch64 ;;
  esac

  ./Configure "$_bt" no-shared no-module no-tests no-docs no-legacy no-engine \
    --prefix="$_ssl" --openssldir=/etc/ssl --libdir=lib -static -fPIC
  make -j "$SB_JOBS" build_libs
  make install_dev
  [ -f "$_ssl/lib/libcrypto.a" ] || die "openssl: libcrypto.a was not installed"
fi

# --- 3. ldid ----------------------------------------------------------------
sb_git https://github.com/ProcursusTeam/ldid.git "$SB_VERSION" ldid
sb_cd "$SB_WORK/src/ldid"

make -j "$SB_JOBS" VERSION="$SB_VERSION" \
  CXXFLAGS="$(sb_cflags) -I$_plist/include -std=c++17 -DHAVE_OPENSSL" \
  LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static) -s" \
  LIBPLIST_INCLUDES="-I$_plist/include" \
  LIBPLIST_LIBS="$_plist/lib/libplist-2.0.a" \
  LIBCRYPTO_INCLUDES="-I$_ssl/include" \
  LIBCRYPTO_LIBS="$_ssl/lib/libcrypto.a"

[ -x ldid ] || { ls -la; die "ldid binary was not produced"; }

sb_bin ldid ldid
sb_bin ldid ldid2
export SB_PATHS="bin"
export SB_ENTRY="bin/ldid"
sb_finish
