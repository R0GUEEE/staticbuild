#!/bin/sh
# deps: build-base make pkgconf openssl-dev libxml2-dev git autoconf automake libtool
# ldid — the signer every jailbreak-adjacent tool needs. Procursus fork:
# entitlements, DER entitlements and ad-hoc signatures for on-device use.
#
# Three things CI proved the hard way:
#  * ldid has no CMakeLists.txt — it is one .cpp plus a Makefile that asks
#    pkg-config for libplist-2.0 and libcrypto;
#  * distro libplist-dev ships no static archive, so a static ldid needs libplist
#    built statically first;
#  * libplist upstream is autotools-first, not CMake. The recipe detects which
#    build system the tarball actually carries instead of assuming.
. "$(dirname "$0")/_common.sh"
sb_init

LIBPLIST_VERSION=${LIBPLIST_VERSION:-2.6.0}
_plist="$SB_WORK/libplist"

if [ ! -f "$_plist/lib/libplist-2.0.a" ]; then
  src=$(sb_fetch "https://github.com/libimobiledevice/libplist/releases/download/$LIBPLIST_VERSION/libplist-$LIBPLIST_VERSION.tar.bz2")
  sb_unpack "$src" "$SB_WORK/src/libplist"
  _root=$(find "$SB_WORK/src/libplist" -maxdepth 2 -type d -name "libplist-*" | head -1)
  [ -n "$_root" ] || die "libplist: tarball has no libplist-* directory"
  sb_cd "$_root"

  if [ -f configure ]; then
    ./configure --prefix="$_plist" --enable-static --disable-shared \
      --without-cython CFLAGS="$(sb_cflags)" LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static)"
    make -j "$SB_JOBS"
  elif [ -f configure.ac ]; then
    ./autogen.sh --prefix="$_plist" --enable-static --disable-shared \
      --without-cython CFLAGS="$(sb_cflags)" LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static)"
    make -j "$SB_JOBS"
  else
    cmake -B out -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$_plist" -DBUILD_SHARED_LIBS=OFF -DENABLE_STATIC=ON \
      -DCMAKE_C_FLAGS="$(sb_cflags)"
    cmake --build out -j "$SB_JOBS"
    cmake --install out
  fi

  [ -f "$_plist/lib/libplist-2.0.a" ] || { make install 2>/dev/null || cmake --install out 2>/dev/null; }
  [ -f "$_plist/lib/libplist-2.0.a" ] || die "libplist: static archive was not installed"
fi

sb_git https://github.com/ProcursusTeam/ldid.git "$SB_VERSION" ldid
sb_cd "$SB_WORK/src/ldid"

# Alpine's openssl-dev ships no libcrypto.a either, so a static ldid needs its
# own OpenSSL. Same flags as tools/openssl: one archive, no engines, no modules.
_ssl=${OPENSSL_PREFIX:-$SB_WORK/openssl}
if [ ! -f "$_ssl/lib/libcrypto.a" ]; then
  _ossl=$(sb_fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION:-3.4.0}/openssl-${OPENSSL_VERSION:-3.4.0}.tar.gz")
  sb_unpack "$_ossl" "$SB_WORK/src/openssl-ldid"
  sb_cd "$SB_WORK/src/openssl-ldid/openssl-${OPENSSL_VERSION:-3.4.0}"
  ./Configure "$([ "$SB_ARCH" = arm64 ] && echo linux-aarch64 || echo linux-x86_64)" \
    no-shared no-module no-tests no-docs no-legacy no-engine \
    --prefix="$_ssl" --openssldir=/etc/ssl --libdir=lib -static -fPIC
  make -j "$SB_JOBS" build_libs
  make install_dev
fi
make -j "$SB_JOBS" VERSION="$SB_VERSION" \
  CXXFLAGS="$(sb_cflags) -I$_plist/include -std=c++17 -DHAVE_OPENSSL" \
  LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static) -s" \
  LIBPLIST_INCLUDES="-I$_plist/include" \
  LIBPLIST_LIBS="$_plist/lib/libplist-2.0.a" \
  LIBCRYPTO_INCLUDES="-I$_ssl/include" \
  LIBCRYPTO_LIBS="$_ssl/lib/libcrypto.a"

[ -x ldid ] || die "ldid binary was not produced"

sb_bin ldid ldid
sb_bin ldid ldid2
export SB_PATHS="bin"
export SB_ENTRY="bin/ldid"
sb_finish
