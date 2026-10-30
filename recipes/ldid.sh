#!/bin/sh
# deps: build-base make pkgconf openssl-dev libxml2-dev git
# ldid — the signer every jailbreak-adjacent tool needs. Procursus fork:
# entitlements, DER entitlements and ad-hoc signatures for on-device use.
#
# Two things CI proved the hard way:
#  * ldid has no CMakeLists.txt — it is one .cpp plus a Makefile that asks
#    pkg-config for libplist-2.0 and libcrypto.
#  * distro libplist-dev ships no static archive, so a static ldid needs
#    libplist built statically first. The recipe does that inline.
. "$(dirname "$0")/_common.sh"
sb_init

LIBPLIST_VERSION=${LIBPLIST_VERSION:-2.6.0}
_plist="$SB_WORK/libplist"

if [ ! -f "$_plist/lib/libplist-2.0.a" ]; then
  src=$(sb_fetch "https://github.com/libimobiledevice/libplist/releases/download/$LIBPLIST_VERSION/libplist-$LIBPLIST_VERSION.tar.bz2")
  sb_unpack "$src" "$SB_WORK/src/libplist"
  # tarball layouts drift; find the CMake project instead of assuming a name
  _plsrc=$(find "$SB_WORK/src/libplist" -maxdepth 3 -name CMakeLists.txt | head -1)
  [ -n "$_plsrc" ] || die "libplist: no CMakeLists.txt in the tarball"
  sb_cd "$(dirname "$_plsrc")"
  cmake -B out -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$_plist" \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_STATIC=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$(sb_cflags)" \
    -DCMAKE_EXE_LINKER_FLAGS="$([ "$SB_FAMILY" = elf ] && echo -static)"
  cmake --build out -j "$SB_JOBS"
  cmake --install out
fi

sb_git https://github.com/ProcursusTeam/ldid.git "$SB_VERSION" ldid
sb_cd "$SB_WORK/src/ldid"

_ssl=${OPENSSL_PREFIX:-/usr}
make -j "$SB_JOBS" \
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
